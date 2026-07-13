$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "finwealth-package-integrity-$([Guid]::NewGuid().ToString('N'))"
$stage = Join-Path $tempRoot "package"
$oldLocalAppData = $env:LOCALAPPDATA

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-LowerHash {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $stage "server") | Out-Null
  Copy-Item -LiteralPath (Join-Path $root "tools\windows_self_use_launcher.ps1") -Destination (Join-Path $stage "Start-Finwealth.ps1")
  Copy-Item -LiteralPath (Join-Path $root "tools\windows_self_use_launcher.cmd") -Destination (Join-Path $stage "Start-Finwealth.cmd")
  Write-Utf8NoBom -Path (Join-Path $stage "finwealth.exe") -Content "dummy-client"
  Write-Utf8NoBom -Path (Join-Path $stage "server\finwealth-server.exe") -Content "dummy-server"

  $build = [ordered]@{
    buildFormat = 2
    dataSource = "local_server"
    apiBase = "http://127.0.0.1:8791"
    serverBundled = $true
    clientVersion = "1.0.0+1"
    serverVersion = "0.1.0"
    sourceCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    sourceDirty = $false
    builtAt = "2026-07-13T00:00:00Z"
  } | ConvertTo-Json -Compress
  $buildPath = Join-Path $stage "finwealth.build-config.json"
  Write-Utf8NoBom -Path $buildPath -Content $build

  $manifest = [ordered]@{
    packageFormat = 2
    clientVersion = "1.0.0+1"
    serverVersion = "0.1.0"
    createdAt = "2026-07-13T00:00:00Z"
    sourceCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    sourceDirty = $false
    dataSource = "local_server"
    apiBase = "http://127.0.0.1:8791"
    client = "finwealth.exe"
    clientSha256 = $(Get-LowerHash -Path (Join-Path $stage "finwealth.exe"))
    server = "server/finwealth-server.exe"
    serverSha256 = $(Get-LowerHash -Path (Join-Path $stage "server\finwealth-server.exe"))
    launcherPowerShell = "Start-Finwealth.ps1"
    launcherPowerShellSha256 = $(Get-LowerHash -Path (Join-Path $stage "Start-Finwealth.ps1"))
    launcherCmd = "Start-Finwealth.cmd"
    launcherCmdSha256 = $(Get-LowerHash -Path (Join-Path $stage "Start-Finwealth.cmd"))
    buildConfig = "finwealth.build-config.json"
    buildConfigSha256 = $(Get-LowerHash -Path $buildPath)
  } | ConvertTo-Json -Compress
  Write-Utf8NoBom -Path (Join-Path $stage "package-manifest.json") -Content $manifest

  $env:LOCALAPPDATA = Join-Path $tempRoot "local-app-data"
  & (Join-Path $stage "Start-Finwealth.ps1") -PackageIntegrityOnly
  if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Finwealth")) {
    throw "PackageIntegrityOnly unexpectedly touched user state"
  }

  Add-Content -LiteralPath (Join-Path $stage "finwealth.exe") -Value "tampered"
  $tamperRejected = $false
  try {
    & (Join-Path $stage "Start-Finwealth.ps1") -PackageIntegrityOnly
  } catch {
    $tamperRejected = $true
  }
  if (!$tamperRejected) {
    throw "launcher integrity check unexpectedly accepted a tampered client"
  }

  Write-Host "OK: Windows package integrity smoke passed"
} finally {
  $env:LOCALAPPDATA = $oldLocalAppData
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
