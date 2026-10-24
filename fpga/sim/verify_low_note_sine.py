"""Measure low-note LUT stair-step images and require interpolation in RTL.

Numerical model of the actual 64-point sine table and DDS phase increment.
It supports, but cannot replace, an electrical or listening measurement.
"""

from pathlib import Path
import math
import re

import numpy as np


src = (Path(__file__).resolve().parents[1] / "src/basic_dds_synth.v").read_text(
    encoding="utf-8"
)
lut = np.array(
    [round(32767 * math.sin(2 * math.pi * i / 64)) for i in range(64)],
    dtype=np.float64,
)
fs = 50_000_000 / 1024
n = np.arange(262144, dtype=np.uint64)
window = np.hanning(n.size)
frequencies = np.fft.rfftfreq(n.size, 1 / fs)


def image_db(note: int) -> tuple[float, float]:
    step_match = re.search(rf"7'd{note}: note_phase_inc = 32'd(\d+)", src)
    assert step_match, note
    step = int(step_match.group(1))
    actual_f = step * fs / 2**32
    phase = ((n * step) & np.uint64(0xFFFFFFFF)).astype(np.float64)
    address = (phase / 2**26).astype(np.int64)
    fraction = (phase % 2**26) / 2**26
    stepped = lut[address]
    smooth = stepped + (lut[(address + 1) & 63] - stepped) * fraction

    def high_band_ratio(signal: np.ndarray) -> float:
        power = np.abs(np.fft.rfft(signal * window)) ** 2
        fundamental = (frequencies > actual_f - 2) & (frequencies < actual_f + 2)
        audible_images = (frequencies > 7000) & (frequencies < 20000)
        return 10 * math.log10(power[audible_images].sum() / power[fundamental].sum())

    return high_band_ratio(stepped), high_band_ratio(smooth)


before, after = image_db(50)
print(f"MIDI 50 7-20 kHz images: stepped {before:.1f} dBc, linear {after:.1f} dBc")
assert before - after > 15, (before, after)
assert "function signed [16:0] sine_interpolated" in src
assert "sine_from_phase(phase_value + 32'h04000000)" in src
print("low-note sine interpolation design: PASS")
