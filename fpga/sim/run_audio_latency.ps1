$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & iverilog -g2012 -s tb_audio_latency -o sim/tb_audio_latency.vvp sim/tb_audio_latency.v src/spi_midi_frame_rx.v src/poly_voice_ctrl.v src/basic_dds_synth.v src/additive32_synth.v src/piano32_poly_synth.v src/echo_delay.v src/pt8211_tx.v
    if ($LASTEXITCODE -ne 0) { throw 'Audio latency test compilation failed' }
    & vvp sim/tb_audio_latency.vvp +VCD | Tee-Object -FilePath sim/audio_latency.log
    if ($LASTEXITCODE -ne 0) { throw 'Audio latency test failed; see sim/audio_latency.log' }
} finally {
    Pop-Location
}
