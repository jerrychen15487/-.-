"""Check the fixed HDMI excerpt against the team's PSC2 source package.

Usage: python tests/check_piano_excerpt.py path/to/burgmuller-05.pseq
"""

import pathlib
import re
import struct
import sys


def entries(source: str, name: str) -> list[int]:
    body = re.search(rf"function integer {name};(.*?)endfunction", source, re.S)
    assert body, f"missing {name}"
    pairs = re.findall(rf"(\d+):\s*{name}\s*=\s*(\d+);", body.group(1))
    return [int(value) for index, value in sorted(pairs, key=lambda p: int(p[0]))]


def main() -> None:
    package = pathlib.Path(sys.argv[1]).read_bytes()
    source = (pathlib.Path(__file__).parents[1] / "src/piano_blocks_demo.v").read_text()
    count = struct.unpack_from("<H", package, 36)[0]
    bpm = struct.unpack_from("<H", package, 54)[0]
    note_section = next(
        struct.unpack_from("<I", package, 64 + i * 32 + 8)[0]
        for i in range(count)
        if struct.unpack_from("<I", package, 64 + i * 32)[0] == 2
    )
    note_count = struct.unpack_from("<I", package, 48)[0]
    notes = [
        struct.unpack_from("<IIBBBBI", package, note_section + i * 16)
        for i in range(note_count)
    ]
    excerpt = [n for n in notes if n[0] < 3840]
    expected = {
        "score_start": [n[0] for n in excerpt],
        "score_length": [n[1] for n in excerpt],
        "score_pitch": [n[2] for n in excerpt],
        "score_part": [n[4] for n in excerpt],
    }
    for name, values in expected.items():
        actual = entries(source, name)
        assert actual == values, f"{name}: FPGA {actual} != PSC2 {values}"
    assert len(excerpt) == 20
    assert bpm == 112
    clock = (pathlib.Path(__file__).parents[1] / "src/score_demo_clock.v").read_text()
    assert "TICK_RATE = 25'd1792" in clock
    assert "PIXEL_HZ = 25'd25000000" in clock
    assert "current_tick == 32'd3839" in clock
    # V18 used rounded video frames; V19 uses native ticks. Its shared Q16
    # vertical scroll must remain within 2 pixels of the website formula.
    for tick in range(3840):
        scroll = tick * 3291 // 65536
        for n in excerpt:
            start = n[0]
            drawn_bottom = 400 + scroll - ((start * 45 + 448) // 896)
            web_scaled_bottom = 400 - (start - tick) * 45 / 896
            assert abs(drawn_bottom - web_scaled_bottom) <= 2
    print("PASS: 20 HDMI excerpt notes match PSC2 ticks, duration, pitch and part")


if __name__ == "__main__":
    main()
