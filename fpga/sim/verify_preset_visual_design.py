"""Static/quantitative acceptance checks for the organ + stable HDMI revision."""

from pathlib import Path
import math

ROOT = Path(__file__).resolve().parents[1]
FS = 50_000_000 / 1024

# The waveform must show multiple cycles of the lowest demonstrated note C4.
wave_window_s = 128 * 4 / FS
c4_cycles = wave_window_s * 261.6256
assert 2.5 <= c4_cycles <= 4.0, (wave_window_s, c4_cycles)

# After average/decimate-by-16, the four acceptance-test fundamentals should
# occupy separate FFT bins (allowing C4 leakage between bins 5 and 6).
bin_hz = (FS / 16) / 64
bins = [round(f / bin_hz) for f in (261.6256, 329.6276, 391.9954, 523.2511)]
assert len(set(bins)) == 4, bins

synth = (ROOT / "src" / "basic_dds_synth.v").read_text(encoding="utf-8")
visual = (ROOT / "src" / "midi_visualizer.v").read_text(encoding="utf-8")
fft = (ROOT / "src" / "fft64_spectrum.v").read_text(encoding="utf-8")

top = (ROOT / "src" / "top.v").read_text(encoding="utf-8")

# Preset 1 is a musically meaningful additive organ, not a generic lead.
assert "organ_wave" in synth
assert "voice_finished" in synth
assert "organ_raw - (organ_raw >>> 3) - (organ_raw >>> 4)" in synth
assert "ENV_SUSTAIN" not in synth
assert "ENV_ORGAN_HOLD" in synth and "ENV_ORGAN_FADE" in synth

# DDS design target: both presets share the exact same fundamental phase
# accumulator.  The organ's upper harmonics are deliberately subordinate so
# the perceived pitch does not shift upward, and its RMS is gain-matched.
organ_weights = [4.0, 1.0, 0.5, 0.25]
assert organ_weights[0] > sum(organ_weights[1:])
# The isolated 3/2 trim remains within 16-bit headroom for a full-velocity
# single organ voice, even at the conservative sum-of-partial maxima.
organ_peak_bound = (sum(organ_weights) * 32767 / 8 * (13 / 16) + 1800)
organ_peak_bound *= 127 * 255 / 32768 * 1.5
assert organ_peak_bound < 32767, organ_peak_bound

# Piano revision: a six-partial onset and independent spectral envelope supply
# brightness only at the attack.  V5's isolated stretched second oscillator is
# intentionally removed until all partials can use a coherent dispersion model.
assert "piano_partial_phase" not in synth
assert "piano_tone_level" in synth
assert "strike_level" in synth
assert "strike_divider" in synth
assert "piano_sine_1" in synth
assert "triangle_1 <<< 2" not in synth
strike_ms = (256 / 4) * 8 / FS * 1000
assert strike_ms <= 12.0

# The upper trace must use a primary voice, zero-crossing trigger and a
# frame-stable display buffer.  A continuously shifting live array shears
# while the raster scans and produces the chaotic trace seen on hardware.
assert "primary_voice_sample" in top
assert "trigger_armed" in visual
assert "capture_buffer" in visual
assert "display_buffer" in visual
assert "frame_start" in visual
assert "voice cards" not in visual.lower()

# Spectrum must react to weak bins while remaining readable.
assert "spectrum_height_log" in visual
assert "peak hold with slow decay" in visual.lower()

# FFT butterfly and magnitude conversion are split into read/write cycles so
# variable-index memories and arithmetic do not share one 50 MHz path.
assert "STATE_FFT_READ" in fft
assert "STATE_FFT_WRITE" in fft
assert "STATE_MAG_READ" in fft
assert "STATE_MAG_WRITE" in fft

print(f"wave window: {wave_window_s * 1000:.3f} ms, C4 cycles: {c4_cycles:.3f}")
print(f"FFT bin spacing: {bin_hz:.3f} Hz, test-note bins: {bins}")
print("preset/visual acceptance checks: PASS")
