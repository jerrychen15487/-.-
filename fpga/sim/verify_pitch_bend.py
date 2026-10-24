"""Check the intended global MIDI pitch-bend range and RTL data path."""

from pathlib import Path
import math
import re


root = Path(__file__).resolve().parents[1]
top = (root / "src/top.v").read_text(encoding="utf-8")
voice = (root / "src/basic_dds_synth.v").read_text(encoding="utf-8")

assert "event_type == 8'h04" in top
assert "{data2[6:0], data1[6:0]}" in top
assert ".bend_factor_q14(bend_factor_q14)" in top
assert "phase <= phase + phase_step_bent" in voice

entries = {
    int(i): int(value)
    for i, value in re.findall(
        r"5'd(\d+): bend_factor_endpoint = 16'd(\d+);", top
    )
}
assert set(entries) == set(range(17)), entries


def factor(value: int) -> int:
    segment, fraction = divmod(value, 1024)
    lo, hi = entries[segment], entries[segment + 1]
    return lo + ((hi - lo) * fraction + 512) // 1024


assert factor(8192) == 16384
assert factor(0) < factor(8192) < factor(16383)
assert all(factor(v) <= factor(v + 1) for v in range(16383))
max_error_cents = max(
    abs(1200 * math.log2(factor(v) / 16384)
        - 2 * (v - 8192) / 8192 * 100)
    for v in range(16384)
)
assert max_error_cents < 1, max_error_cents
steps = [
    int(value)
    for value in re.findall(r"7'd\d+: note_phase_inc = 32'd(\d+);", voice)
]
assert len(steps) == 88
for step in steps:
    assert (step * factor(8192) >> 14) == step
    assert step * factor(16383) >> 14 < 2**32
    assert step * factor(0) >> 14 < step < step * factor(16383) >> 14
print(f"pitch bend: +/-2 semitones, max factor error {max_error_cents:.3f} cents; PASS")
