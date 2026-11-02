$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonExe = 'C:\Users\ASUS\.venvs\codex-tools\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonExe)) {
    throw "Missing user-level Python: $pythonExe"
}
$simExe = Join-Path $env:TEMP 'piano32_spectrum_capture.vvp'
$samples = Join-Path $env:TEMP 'piano32_hdl_samples.txt'
Push-Location $projectRoot
try {
    & iverilog -g2005 -s tb_piano32_spectrum_capture -o $simExe `
        'sim\tb_piano32_spectrum_capture.v' 'src\piano32_poly_synth.v'
    if ($LASTEXITCODE -ne 0) { throw 'Icarus compilation failed' }
    & vvp $simExe "+OUT=$samples"
    if ($LASTEXITCODE -ne 0) { throw 'RTL capture failed' }
    & $pythonExe 'tools\analyze_piano32_hdl_spectrum.py' $samples
    if ($LASTEXITCODE -ne 0) { throw 'Spectrum analysis failed' }
}
finally {
    Pop-Location
}
