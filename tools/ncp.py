"""
Reader for Nikon Picture Control files (.NCP, version "0100", 638 bytes). No M8 knowledge here.

Layout (FINDINGS "JPG tone curves"; the settings meanings are inferred from comparing files):
  0x00  "NCP\\0", 0x08 u32 BE header size 0x24, 0x0C "0100", 0x10 name (20 bytes, NUL padded)
  0x24  settings block (28 bytes): values are offset by 0x80 (0x80 = 0, 0x81 = +1),
        0xFF = not used. 0x28 sharpening (likely); 0x2B / 0x2C saturation / hue (colour bases);
        0x2D / 0x2E filter effect / toning (monochrome bases); 0x3F brightness (likely; baked
        into the stored table)
  0x40  number of curve points, then (x, y) bytes
  0x78  stored tone table: 257 x u16 BE, 0..32767 (what the camera applies; includes brightness)

  read(bytes) -> dict(name, curve, points, kind, settings)
  curve = 256 floats 0..255 (output for each 8-bit input).
"""
import struct

LUT_OFS, LUT_N, LUT_MAX = 0x78, 257, 32767


def _signed(b):
    return None if b == 0xFF else b - 0x80


def read(buf):
    if buf[:4] != b'NCP\0' or len(buf) < LUT_OFS + 2 * LUT_N:
        raise ValueError('not an NCP file')
    lut = struct.unpack_from(f'>{LUT_N}H', buf, LUT_OFS)
    if lut[0] > lut[-1] or max(lut) > LUT_MAX or any(b < a for a, b in zip(lut, lut[1:])):
        raise ValueError('NCP tone table is not a rising curve')
    n = buf[0x40]
    points = [(buf[0x41 + 2 * i], buf[0x42 + 2 * i]) for i in range(min(n, 27))]
    s = {'sharpening': _signed(buf[0x28]), 'saturation': _signed(buf[0x2B]), 'hue': _signed(buf[0x2C]),
         'filter': _signed(buf[0x2D]), 'toning': _signed(buf[0x2E]), 'brightness': buf[0x3F]}
    kind = 'monochrome' if s['saturation'] is None and s['filter'] is not None else 'colour'
    return {'name': buf[0x10:0x24].split(b'\0')[0].decode('latin1').strip(),
            'curve': [lut[v] * 255 / LUT_MAX for v in range(256)],
            'points': points, 'kind': kind, 'settings': s}


def describe(p):
    """One line about the settings the M8 cannot take (best guess, see the module docstring)."""
    s, out = p['settings'], [f'{p["kind"]} base']
    if s['sharpening'] is not None and s['sharpening'] != 3:
        out.append(f'sharpening {s["sharpening"]} (Nikon default 3)')
    for k in ('saturation', 'hue', 'filter', 'toning'):
        if s[k]:
            out.append(f'{k} {s[k]:+d}')
    if s['brightness']:
        out.append(f'brightness {s["brightness"]} (already in the curve)')
    return ', '.join(out)
