#!/usr/bin/env python3
"""
Show what a tone-curve file would do, rendered from your own RAW file (desktop only).

  work/venv/bin/python tools/m8_curvesim.py firmware/stock/m8-2_014.upd X.RAW A.LUT [B.LUT ...]
                                            [--out-dir DIR]

Needs the camera's JPG of the same shot next to the RAW (X.JPG): the JPG teaches the simulator
the camera's colour. The camera's pipeline, as measured (FINDINGS "JPG tone curves"): linear raw
RGB -> clip after white balance -> 3x3 colour matrix -> tone curve of the chosen colour space
(row: from the JPG's ICC profile) and Contrast step -> JPG. Steps here:
  1. align the RAW to the JPG (half size);
  2. find the Contrast step whose curve fits the JPG best, invert it, and fit the 3x3 matrix
     (raw -> linear colour space) on mid-tone pixels;
  3. check: re-render the camera's own curve and compare with the JPG (median difference, in
     8-bit levels; about 2 on the samples);
  4. render each .LUT's sRGB Standard curve from the same linear data, converted to sRGB
     primaries, plus Leica's own for comparison.
Writes NAME-RAW.jpg (full size) per curve and RAW-compare.jpg (contact sheet) into DIR (default
build/curves/). These are your photos: keep them private.
Needs numpy, rawpy, imageio, Pillow (requirements.txt).
"""
import argparse, io, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import m8_profile as mp

N = mp.N


def _xyz(xy):
    return np.array([xy[0] / xy[1], 1, (1 - xy[0] - xy[1]) / xy[1]])


def rgb_to_xyz(prims, white):
    P = np.stack([_xyz(p) for p in prims], 1)
    return P * np.linalg.solve(P, _xyz(white))


D50, D65 = (0.3457, 0.3585), (0.3127, 0.3290)
SPACES = {  # row -> (primaries, white)
    0: ([(0.64, 0.33), (0.21, 0.71), (0.15, 0.06)], D65),     # Adobe RGB (1998)
    1: ([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], D65),     # sRGB
    2: ([(0.67, 0.33), (0.21, 0.71), (0.14, 0.08)], D50),     # ECI RGB v1
}
BRADFORD_D50_D65 = np.array([[0.9555766, -0.0230393, 0.0631636], [-0.0282895, 1.0099416, 0.0210077],
                             [0.0122982, -0.0204830, 1.3299098]])


def to_srgb_linear(row):
    P, W = SPACES[row]
    M = rgb_to_xyz(P, W)
    if W == D50:
        M = BRADFORD_D50_D65 @ M
    return np.linalg.inv(rgb_to_xyz(*SPACES[1])) @ M


def row_of(icc):
    t = (icc or b'').decode('latin1')
    if 'ECI' in t:
        return 2
    if 'Adobe RGB' in t:
        return 0
    return 1


def fit(raw_path, jpg_path, stock):
    """-> dict(lin = linear data in the JPG's colour space (half size), row, contrast, err, jpg)."""
    import rawpy, imageio.v3 as iio
    from PIL import Image
    r = rawpy.imread(raw_path)
    black = float(np.mean(r.black_level_per_channel))
    cam = r.postprocess(gamma=(1, 1), no_auto_bright=True, output_bps=16, user_wb=[1, 1, 1, 1],
                        output_color=rawpy.ColorSpace.raw, half_size=True,
                        user_black=int(black)).astype(np.float64)
    sat = np.percentile(cam.max(-1), 99.99)           # sensor white in decoder units
    cam /= sat
    wb = np.array(r.camera_whitebalance[:3]) / r.camera_whitebalance[1]
    im = Image.open(jpg_path)
    icc = im.info.get('icc_profile')
    row = row_of(icc)
    jp = np.asarray(im.convert('RGB')).astype(np.float64)
    J = (jp[0::2, 0::2] + jp[1::2, 1::2] + jp[0::2, 1::2] + jp[1::2, 0::2]) / 4
    H, W = J.shape[:2]
    gl, jl = np.sqrt(np.clip(cam[..., 1], 0, 1)), J[..., 1]
    _, dy, dx = max((np.corrcoef(gl[y:y + H:4, x:x + W:4].ravel(), jl[::4, ::4].ravel())[0, 1], y, x)
                    for y in range(cam.shape[0] - H + 1) for x in range(cam.shape[1] - W + 1))
    cam = cam[dy:dy + H, dx:dx + W]
    cw = np.minimum(cam * wb, 1.0)                     # clip after white balance
    m = np.all((J > 20) & (J < 235), -1) & np.all(cam < 0.95, -1)
    A, Jm = cw[m][::7], J[m][::7]
    best = None
    for c in range(5):
        curve = np.array(stock[5 * row + c], np.float64)
        inv = np.interp(np.arange(256), *np.unique(curve, return_index=True)) / (N - 1)
        B = inv[np.clip(np.round(Jm), 0, 255).astype(int)]
        M, *_ = np.linalg.lstsq(A, B, rcond=None)
        pred = curve[np.clip(np.round((A @ M) * (N - 1)), 0, N - 1).astype(int)]
        e = float(np.median(np.abs(pred - Jm)))
        if best is None or e < best[0]:
            best = (e, c, M)
    e, c, M = best
    lin = np.clip(cw @ M, 0, 1)
    return {'lin': lin, 'row': row, 'contrast': c, 'err': e, 'icc': icc, 'jpg': im, 'shift': (dy, dx)}


def render(stock_upd, raw_path, luts, out_dir=None):
    from PIL import Image, ImageDraw, ImageFont, ImageCms
    out_dir = out_dir or os.path.join(HERE, '..', 'build', 'curves')
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(raw_path)[0]
    jpg = next((stem + e for e in ('.JPG', '.jpg') if os.path.exists(stem + e)), None)
    if not jpg:
        raise SystemExit(f'error: {raw_path}: needs the camera JPG of the same shot next to it')
    stock = mp.curves_of(mp.stock_gamma(stock_upd))
    f = fit(raw_path, jpg, stock)
    print(f'{os.path.basename(raw_path)}: {mp.ROWS[f["row"]]}, Contrast step {f["contrast"] + 1}; '
          f'simulation vs camera JPG: median {f["err"]:.1f} levels')
    lin_srgb = np.clip(f['lin'] @ to_srgb_linear(f['row']).T, 0, 1)
    idx = np.clip(np.round(lin_srgb * (N - 1)), 0, N - 1).astype(int)
    to_srgb = lambda im: ImageCms.profileToProfile(
        im, ImageCms.ImageCmsProfile(io.BytesIO(f['icc'])), ImageCms.createProfile('sRGB'),
        outputMode='RGB') if f['icc'] else im.convert('RGB')
    tiles = [('Camera JPG', to_srgb(f['jpg']))]
    sim = np.array(stock[5 * f['row'] + f['contrast']], np.uint8)[
        np.clip(np.round(f['lin'] * (N - 1)), 0, N - 1).astype(int)]
    simim = Image.fromarray(sim)
    if f['icc']:
        simim.info['icc_profile'] = f['icc']
    tiles.append(('Simulated camera (check)', to_srgb(simim)))
    curves = [('Leica (stock)', stock[5 + mp.STD])]
    for lut in luts:
        g = open(lut, 'rb').read()
        curves.append((os.path.splitext(os.path.basename(lut))[0], list(g[mp.CURVES_OFS + (5 + mp.STD) * N:][:N])))
    written = []
    rawname = os.path.splitext(os.path.basename(raw_path))[0]
    for name, curve in curves:
        im = Image.fromarray(np.array(curve, np.uint8)[idx])
        tiles.append((name, im))
        if name != 'Leica (stock)':
            p = os.path.join(out_dir, f'{name}-{rawname}.jpg')
            im.save(p, quality=92)
            written.append(p)
    tw = 900
    font = None
    for path in ('/System/Library/Fonts/Helvetica.ttc', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'):
        if os.path.exists(path):
            font = ImageFont.truetype(path, 26)
            break
    font = font or ImageFont.load_default()
    small = []
    for label, im in tiles:
        t = im.copy(); t.thumbnail((tw, tw))
        d = ImageDraw.Draw(t)
        d.rectangle([0, 0, t.width, 38], fill=(0, 0, 0)); d.text((10, 5), label, fill=(255, 255, 255), font=font)
        small.append(t)
    w, h = small[0].size
    sheet = Image.new('RGB', (2 * w + 10, ((len(small) + 1) // 2) * (h + 10)), 'white')
    for i, t in enumerate(small):
        sheet.paste(t.resize((w, h)), ((i % 2) * (w + 10), (i // 2) * (h + 10)))
    p = os.path.join(out_dir, f'{rawname}-compare.jpg')
    sheet.save(p, quality=90)
    return [p] + written


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stock'); ap.add_argument('raw'); ap.add_argument('luts', nargs='+')
    ap.add_argument('--out-dir')
    a = ap.parse_args()
    for p in render(a.stock, a.raw, a.luts, a.out_dir):
        print('wrote', os.path.normpath(p))


if __name__ == '__main__':
    main()
