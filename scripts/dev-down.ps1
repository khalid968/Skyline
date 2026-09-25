# Closes the windows (and the emulator) that dev-up.ps1 opened, with everything
# they started. Anything you started yourself is left alone. Docker keeps
# running, and your data stays: pass -StopDocker to stop the data stack too.
param([switch]$StopDocker)

$root = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $root '.dev-pids'

if (Test-Path $pidFile) {
  foreach ($id in Get-Content $pidFile) {
    if ($id -match '^\d+$' -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
      taskkill /PID $id /T /F | Out-Null
      Write-Host "Closed process $id and its children."
    }
  }
  Remove-Item $pidFile
} else {
  Write-Host 'Nothing to close: no windows were opened by Start Skyline.'
}

if ($StopDocker) {
  docker compose -f (Join-Path $root 'infra\docker\docker-compose.yml') stop
}
Start-Sleep -Seconds 3
