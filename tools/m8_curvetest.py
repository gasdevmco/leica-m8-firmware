#!/usr/bin/env python3
"""
Checks of the tone-curve work (FINDINGS "JPG tone curves"), ~2 s:

  - tools/m8_profile.py: the built-in "leica" tone rebuilds Leica's 15 curves (median 0, max 3
    levels): rows = Adobe RGB / sRGB / ECI RGB encodings, Leica's Contrast steps reproduced;
  - every built-in tone and the profiles in nikonpc/ (if present) give a valid table: 31,760
    bytes, stock header and colour data, 15 curves rising from 0;
  - stage 12 (MODERN built in) differs from stage 11 only inside the GAMMA curves of the LUTS
    lump; the LUTS archive directory, the GAMMA header and every other lump are unchanged; the
    curves equal m8_profile's MODERN table.

Usage:  work/venv/bin/python tools/m8_curvetest.py [-v]
"""
import glob, hashlib, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import m8_dngpatch as d
import m8_profile as mp
from m8_emutest import Results

ROOT = os.path.join(HERE, '..')


def valid(g, new):
    curves = mp.curves_of(new)
    return (len(new) == mp.GAMMA_SIZE, new[:mp.CURVES_OFS] == g[:mp.CURVES_OFS],
            all(c[0] == 0 and all(b >= a for a, b in zip(c, c[1:])) for c in curves))


def main():
    res = Results('-v' in sys.argv)
    upd = os.path.join(ROOT, 'firmware/stock/m8-2_014.upd')
    stock = open(upd, 'rb').read()
    g = mp.stock_gamma(upd)
    st = mp.curves_of(g)

    lei = mp.curves_of(mp.build(g, mp.BUILTIN['leica'](st)))
    diffs = sorted(abs(a - b) for c in range(15) for a, b in zip(st[c], lei[c]))
    res.check('"leica" rebuilds the stock curves (median, max level difference)',
              (diffs[len(diffs) // 2], diffs[-1] <= 3), (0, True))
    for name, fn in mp.BUILTIN.items():
        res.check(f'built-in {name}: valid table', valid(g, mp.build(g, fn(st))), (True, True, True))
    import ncp
    for f in sorted(glob.glob(os.path.join(ROOT, 'nikonpc', '*'))):
        raw = open(f, 'rb').read()
        if raw[:4] == b'NCP\0':
            for base in ('srgb', 'modern', 'leica'):
                t = mp.on_base(ncp.read(raw)['curve'], mp.BUILTIN[base](st))
                res.check(f'{os.path.basename(f)} on {base}: valid table', valid(g, mp.build(g, t)), (True, True, True))

    _, s11 = d.stage_file(stock, 11)
    _, s12 = d.stage_file(stock, 12)
    lo, hi = d.gamma_curves_span(s12)
    res.check('stage 12 vs stage 11: changes only inside the GAMMA curves',
              [(a, b) for a, b in d.changed_ranges(s11, s12) if not (lo <= a and b <= hi)], [])
    res.check('stage 12 PXA == stage 11 PXA (camera-tested code)', d.pxa_of(s12) == d.pxa_of(s11), True)

    def lumps(buf, base=0):
        n, off = struct.unpack_from('<II', buf, base + 4)
        return [struct.unpack_from('<II8s', buf, base + off + 16 * i) for i in range(n)]
    lpos, lsize = d.find_lump(s12, b'LUTS')
    res.check('top-level lump directory unchanged', lumps(s12) == lumps(s11), True)
    res.check('LUTS archive directory unchanged', lumps(s12, lpos) == lumps(s11, lpos), True)
    gpos, gsize = d.find_lump(s12[lpos:lpos + lsize], b'GAMMA')
    g12 = s12[lpos + gpos:lpos + gpos + gsize]
    res.check('GAMMA header and colour data unchanged, size 31,760',
              (g12[:mp.CURVES_OFS] == g[:mp.CURVES_OFS], gsize), (True, mp.GAMMA_SIZE))
    res.check('stage 12 curves == m8_profile MODERN', g12 == mp.build(g, mp.tone_modern()), True)
    res.check('stage 12 curves SHA-256', hashlib.sha256(g12[mp.CURVES_OFS:]).hexdigest(), d.MODERN_CURVES_SHA)
    print(f'{res.ok} passed, {res.bad} failed')
    sys.exit(1 if res.bad else 0)


if __name__ == '__main__':
    main()
