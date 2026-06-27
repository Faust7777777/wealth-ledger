param(
  [int]$Port = 8791,
  [string]$ApiBase = "",
  [string]$Device = "windows"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($ApiBase)) {
  $ApiBase = "http://127.0.0.1:$Port"
}

$FlutterCandidate = Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat"
if (Test-Path $FlutterCandidate) {
  $FlutterExe = $FlutterCandidate
} else {
  $Flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if (!$Flutter) {
    throw "flutter not found. Expected flutter on PATH or at $FlutterCandidate"
  }
  $FlutterExe = $Flutter.Source
}

Write-Host "Starting Finwealth Flutter app"
Write-Host "  Device:  $Device"
Write-Host "  API:     $ApiBase"
Write-Host "  Source:  local_server"

& $FlutterExe run -d $Device `
  --dart-define=DATA_SOURCE=local_server `
  --dart-define=API_BASE=$ApiBase
