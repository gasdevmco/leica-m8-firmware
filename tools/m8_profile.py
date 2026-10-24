#!/usr/bin/env python3
"""
Build an M8 tone-curve file (a GAMMA table for the Blackfin) from a picture profile.

  python3 tools/m8_profile.py firmware/stock/m8-2_014.upd PROFILE [--name NAME] [--out-dir DIR]
                              [--preview image.JPG ...]

PROFILE is a Nikon Picture Control file (.NCP: its 257-step tone curve is used; the other
settings have no M8 equivalent) or a text file of "input,output" points (0-255, one pair per
line, '#' comments), joined by a smooth monotone curve.

The result NAME.LUT (default build/profiles/; NAME = the profile's file name, letters and digits,
max 8, upper case, e.g. portra.ncp -> PORTRA.LUT; the camera lists profiles by this name) is Leica's GAMMA table from your stock file with
each of the 15 curves replaced by profile(curve): the profile is applied on top of Leica's tone,
as Nikon applies it on top of its own, and the Contrast setting keeps working. Header, colour
data and size (31,760 bytes) are unchanged. It contains Leica data: keep it private.

--preview applies the profile curve to camera JPGs (approximation of the in-camera result:
the camera applies it before sharpening and JPEG compression) and writes side-by-side PNGs.
Nothing here touches the camera; the in-camera loader does not exist yet (FINDINGS "JPG tone
curves"). Needs Python 3; --preview also needs numpy and imageio (requirements.txt).
"""
import argparse, hashlib, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from m8_rawpatch import KNOWN_INPUTS, find_lump

GAMMA_SIZE = 31760
CURVES_OFS, NCURVES, CURVE_LEN = 0x410, 15, 0x800
NCP_LUT_OFS, NCP_LUT_N, NCP_MAX = 0x78, 257, 32767


def stock_gamma(upd):
    data = open(upd, 'rb').read()
    if hashlib.sha256(data).hexdigest() not in KNOWN_INPUTS:
        raise SystemExit('error: not Leica\'s stock M8 2.014 update file (SHA-256 does not match)')
    pos, size = find_lump(data, b'LUTS')
    luts = data[pos:pos + size]
    gpos, gsize = find_lump(luts, b'GAMMA')
    g = luts[gpos:gpos + gsize]
    hdr = struct.unpack_from('<5I', g, 0)
    assert gsize == GAMMA_SIZE and hdr[1] == CURVES_OFS and hdr[4] == NCURVES, 'unexpected GAMMA layout'
    assert struct.unpack_from('<I', g, 0x14)[0] == CURVE_LEN
    return g


def ncp_curve(buf):
    """Nikon .NCP: 257 big-endian u16 (0..32767) at 0x78 -> 256 entries 0..255."""
    if buf[:4] != b'NCP\0' or len(buf) < NCP_LUT_OFS + 2 * NCP_LUT_N:
        raise SystemExit('error: not an NCP file')
    lut = struct.unpack_from(f'>{NCP_LUT_N}H', buf, NCP_LUT_OFS)
    if lut[0] > lut[-1] or max(lut) > NCP_MAX:
        raise SystemExit('error: NCP curve out of range')
    name = buf[0x10:0x24].split(b'\0')[0].decode('latin1').strip()
    return [lut[v] * 255 / NCP_MAX for v in range(256)], name


def points_curve(text):
    """'x,y' points 0..255 -> monotone cubic (Fritsch-Carlson) over 0..255."""
    pts = []
    for line in text.splitlines():
        line = line.split('#')[0].strip()
        if line:
            x, y = (float(v) for v in line.replace(';', ',').split(',')[:2])
            pts.append((x, y))
    pts.sort()
    if len(pts) < 2 or pts[0][0] != 0 or pts[-1][0] != 255 or any(
            not 0 <= y <= 255 for _, y in pts) or len({x for x, _ in pts}) != len(pts):
        raise SystemExit('error: need distinct points from x=0 to x=255, y in 0..255')
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    n = len(pts)
    d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(n - 1)]
    m = [d[0]] + [0 if d[i - 1] * d[i] <= 0 else (d[i - 1] + d[i]) / 2 for i in range(1, n - 1)] + [d[-1]]
    for i in range(n - 1):
        if d[i] == 0:
            m[i] = m[i + 1] = 0
        else:
            a, b = m[i] / d[i], m[i + 1] / d[i]
            if a * a + b * b > 9:
                t = 3 / (a * a + b * b) ** 0.5
                m[i], m[i + 1] = t * a * d[i], t * b * d[i]
    out, k = [], 0
    for v in range(256):
        while k < n - 2 and v > xs[k + 1]:
            k += 1
        h = xs[k + 1] - xs[k]
        t = (v - xs[k]) / h
        h00, h10, h01, h11 = 2*t**3 - 3*t**2 + 1, t**3 - 2*t**2 + t, -2*t**3 + 3*t**2, t**3 - t**2
        out.append(min(255.0, max(0.0, h00*ys[k] + h10*h*m[k] + h01*ys[k+1] + h11*h*m[k+1])))
    return out


def apply(curve, g):
    """profile o stock for each of the 15 curves; header and colour data unchanged."""
    out = bytearray(g)
    for c in range(NCURVES):
        o = CURVES_OFS + c * CURVE_LEN
        out[o:o + CURVE_LEN] = bytes(min(255, round(curve[v])) for v in g[o:o + CURVE_LEN])
    assert len(out) == GAMMA_SIZE and out[:CURVES_OFS] == g[:CURVES_OFS]
    return bytes(out)


def plot(curve, g, new, path):
    """Curves as a PNG (no matplotlib): grey = stock Contrast 1-5 (row 1), black = new."""
    import numpy as np, imageio.v3 as iio
    W, H, M = 512, 320, 10
    img = np.full((H + 2 * M, W + 2 * M, 3), 255, np.uint8)
    img[M:M + H, M] = img[M:M + H, M + W - 1] = img[M, M:M + W] = img[M + H - 1, M:M + W] = 200
    def draw(vals, colour):
        for x in range(W):
            y = vals[x * CURVE_LEN // W]
            img[M + H - 1 - round(y * (H - 1) / 255), M + x] = colour
            img[M + H - 1 - round(y * (H - 1) / 255) - 1, M + x] = colour
    for c in range(5):
        draw(g[CURVES_OFS + c * CURVE_LEN:][:CURVE_LEN], (170, 170, 170))
    for c in range(5):
        draw(new[CURVES_OFS + c * CURVE_LEN:][:CURVE_LEN], (0, 0, 0) if c == 2 else (90, 90, 160))
    iio.imwrite(path, img)


def preview(curve, jpg, path):
    import numpy as np, imageio.v3 as iio
    im = iio.imread(jpg)
    lut = np.array([min(255, round(v)) for v in curve], np.uint8)
    h, w = im.shape[:2]
    step = max(1, w // 1200)
    a, b = im[::step, ::step], lut[im[::step, ::step]]
    iio.imwrite(path, np.concatenate([a, np.full((a.shape[0], 8, 3), 255, np.uint8), b], axis=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stock'); ap.add_argument('profile')
    ap.add_argument('--name', help='output name, max 8 letters/digits (default: the profile\'s file name)')
    ap.add_argument('--out-dir', default=os.path.join(HERE, '..', 'build', 'profiles'))
    ap.add_argument('--preview', nargs='*', default=[])
    args = ap.parse_args()

    g = stock_gamma(args.stock)
    raw = open(args.profile, 'rb').read()
    if raw[:4] == b'NCP\0':
        curve, pname = ncp_curve(raw)
    else:
        curve, pname = points_curve(raw.decode('utf-8')), ''
    name = args.name or ''.join(ch for ch in os.path.splitext(os.path.basename(args.profile))[0]
                                if ch.isalnum() and ch.isascii())
    name = name.upper()[:8]
    if not name or not name.isalnum():
        raise SystemExit('error: give --name (letters/digits, max 8)')
    new = apply(curve, g)

    os.makedirs(args.out_dir, exist_ok=True)
    out = os.path.join(args.out_dir, name + '.LUT')
    with open(out, 'wb') as f:
        f.write(new)
    print(f'profile  {args.profile}' + (f'  ("{pname}")' if pname else ''))
    print(f'curve    in 0/32/64/128/192/255 -> ' + ' / '.join(f'{curve[v]:.0f}' for v in (0, 32, 64, 128, 192, 255)))
    print(f'wrote    {os.path.normpath(out)}  ({len(new)} bytes, SHA-256 {hashlib.sha256(new).hexdigest()[:16]}…)')
    print( '         contains Leica data: keep it private, do not share or publish it')
    try:
        plot(curve, g, new, os.path.join(args.out_dir, name + '-curves.png'))
        print(f'curves   {os.path.normpath(os.path.join(args.out_dir, name + "-curves.png"))}')
        for jpg in args.preview:
            p = os.path.join(args.out_dir, f'{name}-{os.path.splitext(os.path.basename(jpg))[0]}.png')
            preview(curve, jpg, p)
            print(f'preview  {os.path.normpath(p)}  (left: camera JPG, right: with {name})')
    except ImportError:
        print('(no numpy/imageio: curve plot and previews skipped)')


if __name__ == '__main__':
    main()
