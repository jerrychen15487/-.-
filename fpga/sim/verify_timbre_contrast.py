"""Guard the documented V6 organ recipe and isolated output gain.

This checks source structure and timings, not acoustic identity with the V6 bitstream.
"""

from pathlib import Path
src = (Path(__file__).resolve().parents[1] / "src/basic_dds_synth.v").read_text(
    encoding="utf-8"
)
organ_mix = src.split("wire signed [18:0] organ_mix_wide =", 1)[1].split(";", 1)[0]
assert "organ_sine_1 <<< 2" in organ_mix
assert "organ_sine_2" in organ_mix
assert "organ_sine_3 >>> 1" in organ_mix
assert "organ_sine_4 >>> 2" in organ_mix
assert "organ_sine_5" not in organ_mix
assert "organ_raw - (organ_raw >>> 3) - (organ_raw >>> 4)" in src
assert "(envelope_level > 8'd240)" in src
assert "phase[28] ? 17'sd1800 : -17'sd1800" in src
assert "envelope_level <= 8'd96" in src
assert "organ_hold_count == 15'd29295" in src
assert "scaled_sample + (scaled_sample >>> 1)" in src
assert "voice_timbre <= timbre_select" in src
assert "voice_timbre ? organ_wave_pipeline : piano_wave_pipeline" in src
assert "ENV_ORGAN_HOLD" in src and "ENV_ORGAN_FADE" in src
fs = 50_000_000 / 1024
click_ms = 15 * 16 / fs * 1000
assert 4.5 < click_ms < 5.5, click_ms
print(f"V6 organ recipe design: PASS; key click ~{click_ms:.2f} ms")
