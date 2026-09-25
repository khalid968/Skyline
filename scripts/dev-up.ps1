# Starts the whole Skyline development environment on this PC, in order:
#   1. Docker Desktop and the data stack (Postgres, Redis, MinIO)
#   2. the server on :3000 (after applying new migrations)
#   3. the admin dashboard on :5173, opened in the browser
#   4. the Android emulator, then the app on it
#   5. the Windows app
# Each long-running part gets its own window, so you can watch its output and
# close it by itself. Anything already running is left alone and reused.
#
# Double-click "Start Skyline.cmd" in the repository folder, or run:
#   powershell -ExecutionPolicy Bypass -File scripts\dev-up.ps1 [-NoAndroid] [-NoWindows] [-NoDashboard]
# "Stop Skyline.cmd" closes the windows this script opened.
#
# This is YOUR development environment (your dev database). Test accounts
# made here are real accounts in that database.
param(
  [switch]$NoAndroid,
  [switch]$NoWindows,
  [switch]$NoDashboard
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root 'apps\backend'
$dashboard = Join-Path $root 'apps\dashboard'
$mobile = Join-Path $root 'apps\mobile'
$sdk = Join-Path $env:LOCALAPPDATA 'Android\sdk'
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$emulator = Join-Path $sdk 'emulator\emulator.exe'
$pidFile = Join-Path $root '.dev-pids'

function Say($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) {
  Write-Host "`n$text" -ForegroundColor Red
  Read-Host 'Press Enter to close'
  exit 1
}
function Listening($port) {
  $null -ne (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}
function WaitFor($what, $seconds, [scriptblock]$ready) {
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $end) {
    if (& $ready) { return }
    Start-Sleep -Seconds 2
  }
  Fail "Timed out waiting for $what."
}
# Opens a new PowerShell window running $command in $dir, and remembers it
# so "Stop Skyline" can close it.
function Window($title, $dir, $command) {
  $script = "`$host.UI.RawUI.WindowTitle = '$title'; Set-Location '$dir'; $command"
  $p = Start-Process powershell -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $script -PassThru
  Add-Content -Path $pidFile -Value $p.Id
}

# --------------------------------------------------------------- 1. Docker
Say 'Docker'
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  $desktop = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'
  if (-not (Test-Path $desktop)) { $desktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe' }
  if (-not (Test-Path $desktop)) { Fail 'Docker Desktop is not installed.' }
  Write-Host 'Starting Docker Desktop (this can take a minute)...'
  Start-Process $desktop
  WaitFor 'Docker Desktop' 240 { docker info *> $null; $LASTEXITCODE -eq 0 }
}
docker compose -f (Join-Path $root 'infra\docker\docker-compose.yml') up -d
if ($LASTEXITCODE -ne 0) { Fail 'The data stack did not start (docker compose up failed).' }
WaitFor 'Postgres, Redis, MinIO and the call relay' 120 {
  # "healthy|running" per container. The call relay (coturn) has no health
  # check, so a container without one counts once it is running.
  $states = docker compose -f (Join-Path $root 'infra\docker\docker-compose.yml') ps --format '{{.Health}}|{{.State}}'
  $notReady = $states | Where-Object {
    $health, $state = $_ -split '\|'
    if ($health) { $health -ne 'healthy' } else { $state -ne 'running' }
  } | Measure-Object
  $notReady.Count -eq 0
}
Write-Host 'Postgres, Redis, MinIO and the call relay are up.'

# ---------------------------------------------------------------- 2. Server
Say 'Server (:3000)'
if (Listening 3000) {
  Write-Host 'Something is already running on port 3000; using it.'
} else {
  if (-not (Test-Path (Join-Path $backend '.env'))) { Fail 'apps\backend\.env is missing (copy .env.example and fill it in).' }
  Push-Location $backend
  npm run migrate:up
  $migrated = $LASTEXITCODE
  Pop-Location
  if ($migrated -ne 0) { Fail 'Migrations failed; see above.' }
  Window 'Skyline server' $backend 'npm run start'
}
WaitFor 'the server' 120 {
  try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 'http://localhost:3000/health').StatusCode -eq 200 } catch { $false }
}
Write-Host 'Server is healthy.'

# ------------------------------------------------------------- 3. Dashboard
if (-not $NoDashboard) {
  Say 'Dashboard (:5173)'
  if (Listening 5173) {
    Write-Host 'Already running.'
  } else {
    Window 'Skyline dashboard' $dashboard 'npm run dev'
    WaitFor 'the dashboard' 90 { Listening 5173 }
  }
  Start-Process 'http://localhost:5173'
}

# --------------------------------------------------------------- 4. Android
if (-not $NoAndroid) {
  Say 'Android emulator'
  if (-not (Test-Path $adb)) { Fail "Android SDK not found at $sdk." }
  $device = (& $adb devices) | Select-String '^(emulator-\d+)\s+device' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
  if (-not $device) {
    $avds = & $emulator -list-avds
    $avd = if ($avds -contains 'Medium_Phone_API_36.1') { 'Medium_Phone_API_36.1' } else { $avds | Select-Object -First 1 }
    if (-not $avd) { Fail 'No Android emulator exists. Create one in Android Studio > Device Manager.' }
    Write-Host "Starting $avd (software graphics, which avoids the GPU crash)..."
    $p = Start-Process $emulator -ArgumentList '-avd', $avd, '-gpu', 'swiftshader_indirect', '-no-snapshot', '-no-boot-anim' -PassThru
    Add-Content -Path $pidFile -Value $p.Id
    WaitFor 'the emulator to appear' 180 {
      $script:device = (& $adb devices) | Select-String '^(emulator-\d+)\s+device' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
      $null -ne $script:device
    }
  }
  WaitFor 'Android to finish booting' 300 { ((& $adb -s $device shell getprop sys.boot_completed) -join '').Trim() -eq '1' }
  Write-Host "$device is ready."
  Window 'Skyline app - Android' $mobile "flutter run -d $device"
}

# --------------------------------------------------------------- 5. Windows
if (-not $NoWindows) {
  Say 'Windows app'
  Window 'Skyline app - Windows' $mobile 'flutter run -d windows'
}

Say 'All started'
Write-Host 'Server:     http://localhost:3000'
if (-not $NoDashboard) { Write-Host 'Dashboard:  http://localhost:5173' }
Write-Host 'The apps take a minute or two to build the first time. In an app window: r = hot reload, R = restart, q = quit.'
Write-Host 'To stop: double-click "Stop Skyline.cmd".'
Start-Sleep -Seconds 8
