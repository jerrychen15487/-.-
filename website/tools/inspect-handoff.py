"""Independent struct/zlib inspection of final bytes; never imports the TS codec.
Run after approving new public packages; --check only compares the frozen manifest.
"""
import hashlib
import json
import struct
import sys
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def inspect(path):
    b = path.read_bytes()
    u16 = lambda p: struct.unpack_from('<H', b, p)[0]
    u32 = lambda p: struct.unpack_from('<I', b, p)[0]
    assert b[:8] == b'PSC2\x02\x00\x00\x00'
    assert u32(8) == len(b) and u16(52) == 960
    sections = []
    for i in range(u16(36)):
        p = 64 + i * 32
        kind, profile, flags, start, length, count, size, reserved, crc, tail = struct.unpack_from('<IHHIIIHHII', b, p)
        assert zlib.crc32(b[start:start+length]) == crc
        sections.append(dict(type=kind, profile=profile, offset=start, length=length,
                             count=count, record_bytes=size, crc32=f'{crc:08X}'))
    by_type = {s['type']: s for s in sections}
    records = lambda kind: range(by_type[kind]['offset'], by_type[kind]['offset']+by_type[kind]['length'], by_type[kind]['record_bytes'])
    pages = []
    for p in records(5):
        page_id, profile, notation, fmt, width, height, stride, reserved, start, length = struct.unpack_from('<IHBBHHHHII', b, p)
        pixels = b[start:start+length]
        assert (profile, fmt, width, height, stride, length) == (1, 1, 960, 480, 120, 57600)
        black = [i*8+bit for i, byte in enumerate(pixels) for bit in range(8) if byte & (128 >> bit)]
        probes = [black[0], black[len(black)//2], black[-1]]
        pages.append(dict(page_id=page_id, notation=notation, bitmap_offset=start,
                          crc32=f'{zlib.crc32(pixels):08X}', black_pixel_count=len(black),
                          black_xy=[[q % width, q // width] for q in probes],
                          corner_values=[int(bool(pixels[q//8] & (128 >> (q % 8)))) for q in [0,959,459840,460799]]))
    anchors = [dict(zip(['tick','page_id','measure','x','y','width','height','notation'], struct.unpack_from('<IIIHHHHB',b,p))) for p in records(7)]
    jumps = []
    for notation in [1,2]:
        route = [a for a in anchors if a['notation'] == notation]
        jumps += [dict(notation=notation,tick=c['tick'],from_page=a['page_id'],to_page=c['page_id']) for a,c in zip(route,route[1:]) if c['page_id'] < a['page_id']]
    return dict(file=path.relative_to(ROOT).as_posix(), id=str(uuid.UUID(bytes=b[12:28])),
                bytes=len(b), crc32=f'{zlib.crc32(b):08X}', sha256=hashlib.sha256(b).hexdigest(),
                blocks=(len(b)+511)//512, tail_bytes=len(b)%512 or 512, bpm=u16(54),
                duration_ticks=u32(32), notes=u32(48), sections=sections, pages=pages,
                anchors=anchors, backward_page_jumps=jumps, safe_starts=[u32(p) for p in records(8)])


paths = sorted((ROOT/'public/scores').glob('*.pseq')) + [ROOT/'tests/fixtures/packages/engineering.pseq']
result = json.dumps([inspect(p) for p in paths], ensure_ascii=False, indent=2)+'\n'
target = ROOT/'tests/fixtures/handoff-packages.json'
if '--check' in sys.argv:
    assert target.read_text(encoding='utf8') == result, 'Final package manifest changed; review before updating'
else:
    target.write_text(result, encoding='utf8')
print(f'Independent CRC/structure/pixel manifest: {len(paths)} packages verified')
