param(
    [ValidateSet('usb','sim','usb-detail')][string]$Mode = 'usb',
    [ValidateSet('bypass','input')][string]$Ready = 'bypass',
    [ValidateSet('off','uart','ble-uart')][string]$Score = 'off',
    [ValidateRange(-1,48)][int]$UartTx = -1,
    [ValidateRange(-1,48)][int]$UartRx = -1,
    [switch]$UartSelfTest,
    [switch]$ScoreDiag,
    [switch]$JoystickDiag,
    [switch]$SteadyMod,
    [switch]$JoystickButtons,
    [ValidateRange(0,48)][int]$Sw1Gpio = 5,
    [ValidateRange(0,48)][int]$Sw2Gpio = 6,
    [ValidateRange(0,48)][int]$Sw3Gpio = 7,
    [ValidateRange(0,48)][int]$Sw4Gpio = 8,
    [ValidateRange(0,48)][int]$Sw5Gpio = 9,
    [ValidateSet('full','quiet')][string]$LogStyle = 'full',
    [string]$IdfPath = 'D:\esp\v6.1\esp-idf',
    [string]$EspressifRoot = 'C:\Espressif'
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
if (($UartTx -eq -1) -ne ($UartRx -eq -1)) { throw 'Set both -UartTx and -UartRx, or leave both unassigned.' }
if ($ScoreDiag -and $Score -eq 'off') { throw '-ScoreDiag requires -Score uart or ble-uart.' }
if ($Score -eq 'off' -and ($UartTx -ne -1 -or $UartSelfTest)) { throw 'UART options require -Score uart or ble-uart.' }
if ($SteadyMod -and -not $JoystickDiag) { throw '-SteadyMod requires -JoystickDiag.' }
if ($JoystickButtons -and -not $JoystickDiag) { throw '-JoystickButtons requires -JoystickDiag.' }
if ($UartSelfTest -and ($Score -ne 'uart' -or $UartTx -eq -1)) {
    throw '-UartSelfTest requires -Score uart and explicit UART1 TX/RX pins.'
}
if ($UartTx -ne -1) {
    $reservedPins = @(0,3,10,11,12,13,19,20,43,44,45,46,48) + @(22..37)
    if ($UartTx -eq $UartRx -or $UartTx -in $reservedPins -or $UartRx -in $reservedPins) {
        throw 'UART pins conflict with USB/SPI/debug, boot straps, flash/PSRAM or unavailable pins. Runtime also checks configured SPI/marker pins.'
    }
}
$env:IDF_PATH = $IdfPath
# EIM stores constraints here; executable paths below are explicit (no idf_tools export).
$env:IDF_TOOLS_PATH = Join-Path $EspressifRoot 'tools'
$env:PYTHONUTF8 = '1'
$env:IDF_PYTHON_ENV_PATH = Join-Path $EspressifRoot 'tools\python\v6.1\venv'
$env:ESP_IDF_VERSION = '6.1'
$env:ESP_ROM_ELF_DIR = Join-Path $EspressifRoot 'tools\esp-rom-elfs\20241011'
$env:IDF_COMPONENT_LOCAL_STORAGE_URL = 'file://' + (Join-Path $EspressifRoot 'tools')
$env:IDF_COMPONENT_CACHE_PATH = Join-Path $projectPath 'build-cache'
$pythonExe = Join-Path $env:IDF_PYTHON_ENV_PATH 'Scripts\python.exe'
$env:PATH = @(
    (Join-Path $env:IDF_PYTHON_ENV_PATH 'Scripts'),
    (Join-Path $EspressifRoot 'tools\xtensa-esp-elf\esp-15.2.0_20251204\xtensa-esp-elf\bin'),
    (Join-Path $EspressifRoot 'tools\cmake\4.0.3\bin'),
    (Join-Path $EspressifRoot 'tools\ninja\1.12.1'),
    (Join-Path $EspressifRoot 'tools\idf-exe\1.0.3'),
    (Join-Path $IdfPath 'tools'), $env:PATH
) -join ';'
$defaults = 'sdkconfig.defaults'
if ($Mode -eq 'sim') { $defaults += ';sdkconfig.sim.defaults' }
if ($Score -ne 'off') { $defaults += ";sdkconfig.score-$Score.defaults" }
# Explicit mode values override stale sdkconfig values from previous experiments.
$settings = [ordered]@{
    BRIDGE_SIM_INPUT = ($Mode -eq 'sim')
    BRIDGE_DETAIL_LOG = ($Mode -eq 'usb-detail')
    BRIDGE_READY_BYPASS = ($Ready -eq 'bypass')
    SCORE_ENABLED = ($Score -ne 'off')
    SCORE_BLE_ENABLED = ($Score -eq 'ble-uart')
    SCORE_UART_SELF_TEST = [bool]$UartSelfTest
    SCORE_DIAGNOSTICS = [bool]$ScoreDiag
    JOYSTICK_DIAGNOSTICS = [bool]$JoystickDiag
    JOYSTICK_STEADY_MODULATION = [bool]$SteadyMod
    JOYSTICK_BUTTONS = [bool]$JoystickButtons
    BT_ENABLED = ($Score -eq 'ble-uart')
}
if ($JoystickButtons) {
    $settings['JOYSTICK_SW1_GPIO'] = $Sw1Gpio
    $settings['JOYSTICK_SW2_GPIO'] = $Sw2Gpio
}
if ($Score -ne 'off') {
    $settings['SCORE_UART_TX_PIN'] = $UartTx
    $settings['SCORE_UART_RX_PIN'] = $UartRx
}
if ($Score -eq 'ble-uart') {
    $settings['BT_NIMBLE_ENABLED'] = $true
    $settings['BT_BLUEDROID_ENABLED'] = $false
    $settings['BT_CONTROLLER_ONLY'] = $false
    $settings['BT_CONTROLLER_ENABLED'] = $true
    $settings['BT_CONTROLLER_DISABLED'] = $false
    $settings['BT_NIMBLE_PINNED_TO_CORE_0'] = $true
    $settings['BT_NIMBLE_PINNED_TO_CORE_1'] = $false
    $settings['BT_CTRL_PINNED_TO_CORE_0'] = $true
    $settings['BT_CTRL_PINNED_TO_CORE_1'] = $false
    $settings['BT_NIMBLE_LOG_LEVEL_WARNING'] = ($LogStyle -eq 'quiet')
    $settings['BT_NIMBLE_LOG_LEVEL_INFO'] = ($LogStyle -eq 'full')
    $settings['BT_NIMBLE_LOG_LEVEL_NONE'] = $false
    $settings['BT_NIMBLE_LOG_LEVEL_ERROR'] = $false
    $settings['BT_NIMBLE_LOG_LEVEL_DEBUG'] = $false
    $settings['BT_NIMBLE_LOG_LEVEL'] = $(if ($LogStyle -eq 'quiet') { 2 } else { 1 })
    $settings['BT_NIMBLE_NVS_PERSIST'] = $false
    $settings['BT_NIMBLE_MAX_CONNECTIONS'] = 1
}
$profileLines = @()
foreach ($entry in $settings.GetEnumerator()) {
    $line = if ($entry.Value -is [bool]) {
        if ($entry.Value) { "CONFIG_$($entry.Key)=y" } else { "# CONFIG_$($entry.Key) is not set" }
    } else { "CONFIG_$($entry.Key)=$($entry.Value)" }
    $profileLines += $line
}
$buildName = if ($Score -eq 'off') { "build-$Mode" } else { "build-$Mode-score-$Score" }
if ($ScoreDiag) { $buildName += "-diag" }
if ($LogStyle -eq 'quiet') { $buildName += "-quiet" }
if ($JoystickDiag) { $buildName += "-joystick" }
if ($SteadyMod) { $buildName += "-steady-mod" }
$buildPath = Join-Path $projectPath $buildName
New-Item -ItemType Directory -Force $buildPath | Out-Null
& $pythonExe (Join-Path $PSScriptRoot 'build_receipt.py') 'begin' '--build' $buildPath
if ($LASTEXITCODE -ne 0) { throw 'Could not invalidate the previous build receipt.' }
[IO.File]::WriteAllLines((Join-Path $buildPath 'mode.defaults'), $profileLines, [Text.UTF8Encoding]::new($false))
$defaults += ";$buildName/mode.defaults"
$configRelative = if ($Score -eq 'off') { "sdkconfig.$Mode" } else { "$buildName/sdkconfig" }
$configPath = Join-Path $projectPath $configRelative
if (Test-Path -LiteralPath $configPath) {
    $configText = [IO.File]::ReadAllText($configPath)
    foreach ($entry in $settings.GetEnumerator()) {
        $configText = [regex]::Replace($configText, "(?m)^(?:CONFIG_$($entry.Key)=.*|# CONFIG_$($entry.Key) is not set)\r?\n?", '')
    }
    $configText = $configText.TrimEnd() + "`n" + ($profileLines -join "`n") + "`n"
    [IO.File]::WriteAllText($configPath, $configText, [Text.UTF8Encoding]::new($false))
}
Write-Host "Building input=$Mode READY=$Ready score=$Score diagnostics=$ScoreDiag joystick=$JoystickDiag logs=$LogStyle UART1_TX=$UartTx UART1_RX=$UartRx (no flash or serial monitor)"
Push-Location $projectPath
try {
    & $pythonExe (Join-Path $IdfPath 'tools\idf.py') '-B' $buildName `
        '-D' "SDKCONFIG=$configRelative" '-D' "SDKCONFIG_DEFAULTS=$defaults" `
        '-D' 'IDF_TARGET=esp32s3' 'build'
    if ($LASTEXITCODE -ne 0) { throw "ESP-IDF $Mode build failed ($LASTEXITCODE)" }
    & $pythonExe (Join-Path $PSScriptRoot 'build_receipt.py') 'finish' '--build' $buildPath
    if ($LASTEXITCODE -ne 0) { throw 'Build receipt validation failed; do not package these images.' }
} finally { Pop-Location }
