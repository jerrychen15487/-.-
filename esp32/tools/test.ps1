param(
    [string]$Compiler = 'D:\mingw\mingw64\bin\gcc.exe',
    [string]$Python = 'C:\Espressif\tools\python\v6.1\venv\Scripts\python.exe'
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
Push-Location $projectPath
try {
    New-Item -ItemType Directory -Force 'build-tests' | Out-Null
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' '-I' 'main' `
        'tests/test_midi.c' 'main/midi_codec.c' 'main/midi_descriptors.c' '-o' 'build-tests/test_midi.exe'
    if ($LASTEXITCODE -ne 0) { throw "Desktop compilation failed ($LASTEXITCODE)" }
    & '.\build-tests\test_midi.exe'
    if ($LASTEXITCODE -ne 0) { throw "Desktop tests failed ($LASTEXITCODE)" }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
        '-I' 'main' 'tests/test_bridge_latency_stats.c' '-o' 'build-tests/test_bridge_latency_stats.exe'
    if ($LASTEXITCODE -ne 0) { throw "Bridge latency test compilation failed ($LASTEXITCODE)" }
    & '.\build-tests\test_bridge_latency_stats.exe'
    if ($LASTEXITCODE -ne 0) { throw "Bridge latency tests failed ($LASTEXITCODE)" }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-Wno-unused-parameter' '-pedantic' `
        '-I' 'tests/host_stubs' '-I' 'main' 'tests/test_usb_startup.c' '-o' 'build-tests/test_usb_startup.exe'
    if ($LASTEXITCODE -ne 0) { throw "USB startup test compilation failed ($LASTEXITCODE)" }
    & '.\build-tests\test_usb_startup.exe'
    if ($LASTEXITCODE -ne 0) { throw "USB startup lifecycle tests failed ($LASTEXITCODE)" }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
        '-DCONFIG_BRIDGE_DETAIL_LOG=1' '-I' 'tests/host_stubs' '-I' 'main' `
        'tests/test_event_trace.c' '-o' 'build-tests/test_event_trace.exe'
    if ($LASTEXITCODE -ne 0) { throw "Trace test compilation failed ($LASTEXITCODE)" }
    & '.\build-tests\test_event_trace.exe'
    if ($LASTEXITCODE -ne 0) { throw "Trace tests failed ($LASTEXITCODE)" }
    foreach ($diagnostics in @(0, 1)) {
        $diagSources = @('tests/test_score_diag.c')
        if ($diagnostics) { $diagSources += @('main/score_diag.c', 'main/score_protocol.c') }
        & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
            "-DCONFIG_SCORE_DIAGNOSTICS=$diagnostics" '-I' 'main' @diagSources `
            '-o' "build-tests/test_score_diag_$diagnostics.exe"
        if ($LASTEXITCODE -ne 0) { throw 'Diagnostic test compilation failed' }
        & ".\build-tests\test_score_diag_$diagnostics.exe"
        if ($LASTEXITCODE -ne 0) { throw 'Diagnostic tests failed' }
    }
    foreach ($name in @('protocol', 'json', 'proxy')) {
        $sources = @("tests/test_score_$name.c", 'main/score_protocol.c')
        if ($name -in @('json', 'proxy')) { $sources += 'main/score_json.c' }
        if ($name -eq 'proxy') { $sources += 'main/score_proxy.c' }
        & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' '-I' 'main' `
            @sources '-o' "build-tests/test_score_$name.exe"
        if ($LASTEXITCODE -ne 0) { throw "Score $name compilation failed ($LASTEXITCODE)" }
        & ".\build-tests\test_score_$name.exe"
        if ($LASTEXITCODE -ne 0) { throw "Score $name tests failed ($LASTEXITCODE)" }
    }
    & $Python 'tools/score_vectors.py' '--check' '--verify-json' 'build-tests/test_score_json.exe'
    if ($LASTEXITCODE -ne 0) { throw "Independent score vectors failed ($LASTEXITCODE)" }
    foreach ($name in @('uart', 'ble')) {
        & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
            '-I' 'tests/score_stubs' '-I' 'main' "tests/test_score_$name.c" '-o' "build-tests/test_score_$name.exe"
        if ($LASTEXITCODE -ne 0) { throw "Score $name lifecycle compilation failed ($LASTEXITCODE)" }
        & ".\build-tests\test_score_$name.exe"
        if ($LASTEXITCODE -ne 0) { throw "Score $name lifecycle tests failed ($LASTEXITCODE)" }
    }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
        '-DCONFIG_SCORE_DIAGNOSTICS=1' '-I' 'tests/score_stubs' '-I' 'main' `
        'tests/test_score_ble.c' 'main/score_diag.c' 'main/score_protocol.c' '-o' 'build-tests/test_score_ble_diag.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic BLE compilation failed' }
    & '.\build-tests\test_score_ble_diag.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic BLE lifecycle tests failed' }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
        '-DCONFIG_SCORE_DIAGNOSTICS=1' '-I' 'main' 'tests/test_score_proxy.c' `
        'tests/score_diag_host.c' 'main/score_diag.c' 'main/score_protocol.c' `
        'main/score_json.c' 'main/score_proxy.c' '-o' 'build-tests/test_score_proxy_diag.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic proxy compilation failed' }
    & '.\build-tests\test_score_proxy_diag.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic proxy regression failed' }
    foreach ($selfTest in @(1, 0)) {
        & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' `
            "-DCONFIG_SCORE_UART_SELF_TEST=$selfTest" '-I' 'tests/score_stubs' '-I' 'main' `
            'tests/test_score_service.c' 'main/score_protocol.c' '-o' "build-tests/test_score_service_$selfTest.exe"
        if ($LASTEXITCODE -ne 0) { throw "Score service test compilation failed ($LASTEXITCODE)" }
        & ".\build-tests\test_score_service_$selfTest.exe"
        if ($LASTEXITCODE -ne 0) { throw "Score service self-test=$selfTest tests failed ($LASTEXITCODE)" }
    }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' '-fsyntax-only' `
        '-DSCORE_TEST_CONST_UNASSIGNED=1' '-I' 'tests/score_stubs' '-I' 'main' 'main/score_uart.c'
    if ($LASTEXITCODE -ne 0) { throw "Unassigned UART GPIO compilation failed ($LASTEXITCODE)" }
    & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-pedantic' '-shared' '-I' 'main' `
        'tests/score_proxy_adapter.c' 'main/score_proxy.c' 'main/score_protocol.c' 'main/score_json.c' `
        '-o' 'build-tests/score_proxy_adapter.dll'
    if ($LASTEXITCODE -ne 0) { throw "Score integration adapter compilation failed ($LASTEXITCODE)" }
    & $Python '-m' 'unittest' 'discover' '-s' 'tests' '-p' 'test_score_*.py' '-v'
    if ($LASTEXITCODE -ne 0) { throw "Score PC / integration tests failed ($LASTEXITCODE)" }
    $websitePath = if ($env:SCORE_WEBSITE_PATH) { $env:SCORE_WEBSITE_PATH } else { Join-Path (Split-Path $projectPath -Parent) 'piano-score-library' }
    & $Python (Join-Path $websitePath 'tools/inspect-handoff.py') '--check'
    if ($LASTEXITCODE -ne 0) { throw "Independent PSC2 sample manifest failed ($LASTEXITCODE)" }
} finally { Pop-Location }
