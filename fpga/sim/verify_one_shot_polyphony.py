"""Check the one-shot voice lifecycle and the four-voice signal path.

This is a structural/timing check; audible balance still needs board listening.
"""

from pathlib import Path
import math
import re

root = Path(__file__).resolve().parents[1]
synth = (root / "src/basic_dds_synth.v").read_text(encoding="utf-8")
ctrl = (root / "src/poly_voice_ctrl.v").read_text(encoding="utf-8")
top = (root / "src/top.v").read_text(encoding="utf-8")
fs = 50_000_000 / 1024

assert "voice_finished" in synth and "voice_finished" in ctrl
assert "envelope_state <= ENV_IDLE" in synth
for i in range(4):
    finished_clears_gate = re.search(
        rf"if\s*\(voice_finished\[{i}\]\)\s*begin\s*"
        rf"gate\[{i}\]\s*<=\s*1'b0;.*?end",
        ctrl,
        re.DOTALL,
    )
    assert finished_clears_gate, f"voice_finished[{i}] must clear gate[{i}]"
assert "ENV_SUSTAIN" not in synth
assert "piano_sustain_level" not in synth
assert "organ_raw - (organ_raw >>> 3) - (organ_raw >>> 4)" in synth
assert "ENV_ORGAN_HOLD" in synth and "ENV_ORGAN_FADE" in synth
assert "voice_timbre <= timbre_select" in synth
assert "voice_timbre ? organ_wave_pipeline : piano_wave_pipeline" in synth
assert "phase[28] ? 17'sd1800 : -17'sd1800" in synth

# The piano and organ have different finite, one-shot envelopes.
first_s = (255 - 112) * 256 / fs
upper_s = first_s + 112 * 256 / fs
low_s = first_s + 112 * 512 / fs
assert 1.25 < upper_s < 1.5, upper_s
assert 1.8 < low_s < 2.1, low_s
organ_s = 64 / fs + (255 - 96) * 16 / fs + 29296 / fs + 96 * 80 / fs
assert 0.80 < organ_s < 0.83, organ_s
click_s = 15 * 16 / fs
assert 0.0045 < click_s < 0.0055, click_s

# Four independent phase/envelope blocks feed one signed sum and one DAC.
for i in range(4):
    assert f"basic_dds_synth u_voice{i}" in top
    assert f"voice{i}_sample" in top
assert "wire signed [17:0] mix_sum" in top
assert "wire signed [15:0] audio_sample = mix_sum >>> 2" in top
assert ".sample_left(audio_sample), .sample_right(audio_sample)" in top

print(f"one-shot/polyphony checks: PASS; piano {upper_s:.2f}/{low_s:.2f}s, organ {organ_s:.2f}s")
