#!/usr/bin/env python3
"""
Build an M8 tone-curve file (a GAMMA table for the Blackfin) from a picture profile.

  python3 tools/m8_profile.py firmware/stock/m8-2_014.upd PROFILE [--base srgb|modern|leica]
                              [--name NAME] [--out-dir DIR] [--preview X.RAW ...]

PROFILE is one of
  - a Nikon Picture Control file (.NCP): its stored tone table is used; the other settings have
    no M8 equivalent and are only reported (tools/ncp.py);
  - a text file of "input,output" points (0-255, one pair per line, '#' comments), joined by a
    smooth monotone curve;
  - a built-in tone: modern (sRGB with a soft highlight shoulder and a gentle S, mid-grey 125),
    moderndr (the same for shooting at -1 EV: about a stop more highlight room), srgb (plain),
    leica (Leica's own tone through this tool, within 3 levels of stock), stock (an exact copy
    of Leica's table: to get Leica's curves back on a build with another built-in default).
An NCP or points profile is applied on top of a base tone: srgb (default; how Nikon profiles are
meant, on a neutral image), modern, or leica (Leica's brighter curve).

How the camera uses the table (FINDINGS "JPG tone curves"): 15 curves = 3 colour-space rows
(Adobe RGB = gamma 2.2, sRGB, ECI RGB = gamma 1.8) x 5 Contrast steps, input = linear sensor data
(0..2047 = black..white). Leica made one tone per Contrast step and encoded it per row; so does
this tool: the profile's tone at Contrast "Standard", Leica's own Contrast steps applied around
it, each encoded for the three colour spaces. A profile looks the same in every colour space and
the Contrast menu keeps working.

The result NAME.LUT (default build/profiles/; NAME = the profile's file name, letters and digits,
max 8, upper case, e.g. portra.ncp -> PORTRA.LUT; the camera lists profiles by this name) is
Leica's GAMMA table from your stock file with the 15 curves replaced. Header, colour data and
size (31,760 bytes) are unchanged. It contains Leica data: keep it private.

--preview renders the new curve from your own RAW files (tools/m8_curvesim.py; needs the camera's
JPG of the same shot next to each RAW). Needs Python 3; previews and the curve plot need numpy,
imageio, rawpy and Pillow (requirements.txt).
"""
import argparse, hashlib, math, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from m8_rawpatch import KNOWN_INPUTS, find_lump
import ncp

GAMMA_SIZE = 31760
CURVES_OFS, NCURVES, CURVE_LEN = 0x410, 15, 0x800
ROWS = ('Adobe RGB', 'sRGB', 'ECI RGB')     # row r = curves 5r..5r+4, Contrast Low..High
STD = 2                                     # Contrast "Standard" = column 2
N = CURVE_LEN                               # 2048 input steps, linear


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


def curves_of(g):
    return [list(g[CURVES_OFS + k * CURVE_LEN:][:CURVE_LEN]) for k in range(NCURVES)]


# ---- encodings (values 0..255 <-> display-linear 0..1)
def srgb_enc(L):
    return 255 * (12.92 * L if L <= 0.0031308 else 1.055 * L ** (1 / 2.4) - 0.055)


def srgb_dec(v):
    v /= 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def row_values(s):
    """sRGB-encoded tone -> (Adobe RGB, sRGB, ECI RGB) encodings, as Leica's rows."""
    L = [srgb_dec(v) for v in s]
    return [[255 * l ** (1 / 2.2) for l in L], list(s), [255 * l ** (1 / 1.8) for l in L]]


def interp(xs, ys, v):
    """piecewise-linear y(v) for rising xs (ties averaged)."""
    lo, hi = 0, len(xs) - 1
    if v <= xs[0]:
        return ys[0]
    if v >= xs[-1]:
        return ys[-1]
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if xs[mid] <= v:
            lo = mid
        else:
            hi = mid
    t = (v - xs[lo]) / (xs[hi] - xs[lo]) if xs[hi] != xs[lo] else 0
    return ys[lo] + t * (ys[hi] - ys[lo])


def contrast_maps(stock):
    """Leica's Contrast steps as maps on the sRGB row: standard value -> value at step c."""
    std = stock[5 + STD]
    maps = []
    for c in range(5):
        pairs = sorted(set(zip(std, stock[5 + c])))
        xs, ys = [], []
        for x, y in pairs:                          # average the outputs of equal inputs
            if xs and xs[-1] == x:
                ys[-1] = (ys[-1] + y) / 2
            else:
                xs.append(x); ys.append(y)
        maps.append((xs, ys))
    return maps


# ---- tones (sRGB-encoded, N floats 0..255, Contrast "Standard")
def tone_srgb():
    return [srgb_enc(i / (N - 1)) for i in range(N)]


def tone_modern(mid=0.18, grey=125.0, s_curve=0.10):
    """Reinhard-style shoulder (white = sensor clip), sRGB, gentle S; `mid` linear lands at `grey`."""
    def make(e):
        out = []
        for i in range(N):
            x = e * i / (N - 1)
            t = x * (1 + x / e ** 2) / (1 + x)
            s = srgb_enc(t) / 255
            s += s_curve * s * (1 - s) * (s - 0.5) * 4
            out.append(255 * min(1.0, max(0.0, s)))
        return out
    lo, hi = 0.5, 40.0                               # exposure so that mid-grey -> `grey`
    for _ in range(60):
        e = math.sqrt(lo * hi)
        if make(e)[round(mid * (N - 1))] < grey:
            lo = e
        else:
            hi = e
    return make(math.sqrt(lo * hi))


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


BUILTIN = {'modern': lambda st: tone_modern(),
           'moderndr': lambda st: tone_modern(mid=0.09),
           'srgb': lambda st: tone_srgb(),
           'leica': lambda st: [float(v) for v in st[5 + STD]]}


def on_base(curve256, base):
    """8-bit profile curve applied to a base tone (both sRGB-encoded)."""
    return [interp(list(range(256)), curve256, v) for v in base]


def build(g, tone):
    """GAMMA table: `tone` (sRGB-encoded, Contrast Standard) -> 5 Contrast steps (Leica's own
    maps) x 3 colour-space encodings. Header and colour data from the stock table."""
    stock = curves_of(g)
    maps = contrast_maps(stock)
    out = bytearray(g)
    for c, (xs, ys) in enumerate(maps):
        s = [interp(xs, ys, v) for v in tone]
        s[0] = 0.0                                    # black stays black
        for r, vals in enumerate(row_values(s)):
            o = CURVES_OFS + (5 * r + c) * CURVE_LEN
            prev = 0
            for i, v in enumerate(vals):              # 8-bit, never falling
                prev = max(prev, min(255, round(v)))
                out[o + i] = prev
    assert len(out) == GAMMA_SIZE and out[:CURVES_OFS] == g[:CURVES_OFS]
    return bytes(out)


def plot(g, new, path):
    """sRGB row as a PNG over stops from mid-grey: grey = Leica's 5 Contrast steps, black = new
    Standard, blue = new other steps."""
    import numpy as np, imageio.v3 as iio
    W, H, M = 640, 360, 12
    img = np.full((H + 2 * M, W + 2 * M, 3), 255, np.uint8)
    img[M:M + H, M] = img[M:M + H, M + W - 1] = img[M, M:M + W] = img[M + H - 1, M:M + W] = 200
    lo = -8.0                                          # stops below mid-grey at the left edge
    hi = math.log2(1 / 0.18)
    for s in range(-8, 3):
        img[M:M + H, M + round((s - lo) / (hi - lo) * (W - 1))] = 235 if s else 190
    def draw(curve, colour):
        for X in range(W):
            x = 0.18 * 2 ** (lo + X / (W - 1) * (hi - lo))
            y = curve[min(N - 1, round(x * (N - 1)))]
            Y = M + H - 1 - round(y * (H - 1) / 255)
            img[Y - 1:Y + 1, M + X] = colour
    for c in range(5):
        draw(g[CURVES_OFS + (5 + c) * CURVE_LEN:][:CURVE_LEN], (175, 175, 175))
    for c in range(5):
        draw(new[CURVES_OFS + (5 + c) * CURVE_LEN:][:CURVE_LEN], (0, 0, 0) if c == STD else (90, 90, 170))
    iio.imwrite(path, img)


def stops_line(curve):
    return ' '.join(f'{curve[min(N - 1, round(0.18 * 2 ** s * (N - 1)))]:4.0f}' for s in (-5, -3, -2, -1, 0, 1, 2, 2.47))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stock')
    ap.add_argument('profile', help='.NCP file, points file, or ' + ' / '.join(BUILTIN) + ' / stock')
    ap.add_argument('--base', choices=('srgb', 'modern', 'leica'), default='srgb',
                    help='base tone under an NCP or points profile (default srgb)')
    ap.add_argument('--name', help='output name, max 8 letters/digits (default: the profile\'s file name)')
    ap.add_argument('--out-dir', default=os.path.join(HERE, '..', 'build', 'profiles'))
    ap.add_argument('--preview', nargs='*', default=[], metavar='RAW',
                    help='render from these RAW files (camera JPG of the same shot alongside)')
    args = ap.parse_args()

    g = stock_gamma(args.stock)
    stock = curves_of(g)
    info = ''
    if args.profile.lower() == 'stock':
        tone, stem, info = None, 'leica', 'exact copy of Leica\'s table'
    elif args.profile.lower() in BUILTIN:
        tone = BUILTIN[args.profile.lower()](stock)
        stem, info = args.profile.lower(), 'built-in tone'
    else:
        raw = open(args.profile, 'rb').read()
        if raw[:4] == b'NCP\0':
            try:
                p = ncp.read(raw)
            except ValueError as e:
                raise SystemExit(f'error: {e}')
            curve, info = p['curve'], f'NCP "{p["name"]}": {ncp.describe(p)}'
        else:
            curve, info = points_curve(raw.decode('utf-8')), 'points'
        tone = on_base(curve, BUILTIN[args.base](stock))
        info += f'; on {args.base} base'
        stem = os.path.splitext(os.path.basename(args.profile))[0]
    name = (args.name or ''.join(ch for ch in stem if ch.isalnum() and ch.isascii())).upper()
    if not name or not name.isalnum() or len(name) > 8:
        raise SystemExit(f'error: name "{name}": use --name with 1-8 letters/digits')
    new = g if tone is None else build(g, tone)

    os.makedirs(args.out_dir, exist_ok=True)
    out = os.path.join(args.out_dir, name + '.LUT')
    with open(out, 'wb') as f:
        f.write(new)
    print(f'profile  {args.profile}  ({info})')
    print( '         stops from mid-grey  -5   -3   -2   -1    0   +1   +2  clip')
    print(f'Leica    sRGB, Standard     {stops_line(stock[5 + STD])}')
    print(f'{name:8s} sRGB, Standard     {stops_line(new[CURVES_OFS + (5 + STD) * CURVE_LEN:][:CURVE_LEN])}')
    print(f'wrote    {os.path.normpath(out)}  ({len(new)} bytes, SHA-256 {hashlib.sha256(new).hexdigest()[:16]}…)')
    print( '         contains Leica data: keep it private, do not share or publish it')
    try:
        p = os.path.join(args.out_dir, name + '-curves.png')
        plot(g, new, p)
        print(f'curves   {os.path.normpath(p)}')
    except ImportError:
        print('(no numpy/imageio: curve plot skipped)')
    if args.preview:
        import m8_curvesim
        for rawf in args.preview:
            for p in m8_curvesim.render(args.stock, rawf, [out], args.out_dir):
                print(f'preview  {os.path.normpath(p)}')


if __name__ == '__main__':
    main()
