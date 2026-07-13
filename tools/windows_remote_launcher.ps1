param(
  [switch]$CheckOnly,
  [switch]$PackageIntegrityOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$InstallDir = $PSScriptRoot
$ClientExe = Join-Path $InstallDir "finwealth.exe"
$PackageManifestPath = Join-Path $InstallDir "package-manifest.json"
$BuildConfigPath = Join-Path $InstallDir "finwealth.build-config.json"

function Test-HttpsApiBase {
  param([string]$Value)
  $parsed = $null
  return ![string]::IsNullOrWhiteSpace($Value) -and
    [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$parsed) -and
    $parsed.Scheme -ceq "https" -and
    ![string]::IsNullOrWhiteSpace($parsed.Host) -and
    [string]::IsNullOrEmpty($parsed.UserInfo) -and
    $parsed.AbsolutePath -ceq "/" -and
    [string]::IsNullOrEmpty($parsed.Query) -and
    [string]::IsNullOrEmpty($parsed.Fragment)
}

function Assert-PackageIntegrity {
  $manifest = Get-Content -Raw -LiteralPath $PackageManifestPath | ConvertFrom-Json
  $build = Get-Content -Raw -LiteralPath $BuildConfigPath | ConvertFrom-Json
  $endpointIsValid = switch ([string]$manifest.endpointMode) {
    "fixed" { Test-HttpsApiBase ([string]$manifest.apiBase) }
    "runtime" { [string]::IsNullOrEmpty([string]$manifest.apiBase) }
    default { $false }
  }
  if (
    $manifest.packageFormat -ne 3 -or
    [string]$manifest.clientVersion -eq "" -or
    [string]$manifest.sourceCommit -notmatch '^[0-9a-fA-F]{40}$' -or
    $manifest.sourceDirty -isnot [bool] -or
    $manifest.dataSource -cne "api_remote" -or
    !$endpointIsValid -or
    $manifest.client -cne "finwealth.exe" -or
    [string]$manifest.clientSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.launcherPowerShell -cne "Start-Finwealth.ps1" -or
    [string]$manifest.launcherPowerShellSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.launcherCmd -cne "Start-Finwealth.cmd" -or
    [string]$manifest.launcherCmdSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.buildConfig -cne "finwealth.build-config.json" -or
    [string]$manifest.buildConfigSha256 -notmatch '^[0-9a-fA-F]{64}$'
  ) {
    throw "Package manifest is invalid or does not describe a remote Finwealth client."
  }
  if (
    $build.buildFormat -ne 3 -or
    $build.dataSource -cne "api_remote" -or
    $build.endpointMode -cne $manifest.endpointMode -or
    $build.apiBase -cne $manifest.apiBase -or
    $build.serverBundled -ne $false -or
    $build.clientVersion -cne $manifest.clientVersion -or
    $build.sourceCommit -cne $manifest.sourceCommit -or
    $build.sourceDirty -ne $manifest.sourceDirty
  ) {
    throw "Flutter build metadata does not match the remote client package."
  }
  foreach ($check in @(
    @($ClientExe, [string]$manifest.clientSha256, "client"),
    @((Join-Path $InstallDir "Start-Finwealth.ps1"), [string]$manifest.launcherPowerShellSha256, "PowerShell launcher"),
    @((Join-Path $InstallDir "Start-Finwealth.cmd"), [string]$manifest.launcherCmdSha256, "CMD launcher"),
    @($BuildConfigPath, [string]$manifest.buildConfigSha256, "build config")
  )) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $check[0]).Hash.ToLowerInvariant()
    if ($actual -cne $check[1].ToLowerInvariant()) {
      throw "Packaged $($check[2]) checksum does not match package-manifest.json."
    }
  }
  return $manifest
}

foreach ($required in @(
  $ClientExe,
  $PackageManifestPath,
  $BuildConfigPath,
  (Join-Path $InstallDir "Start-Finwealth.ps1"),
  (Join-Path $InstallDir "Start-Finwealth.cmd")
)) {
  if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Remote client package input is missing: $required"
  }
}

$manifest = Assert-PackageIntegrity
if ($PackageIntegrityOnly) {
  Write-Host "Remote client package integrity check passed."
  return
}

if ($manifest.endpointMode -ceq "fixed") {
  try {
    $health = Invoke-RestMethod -Uri "$($manifest.apiBase)/v1/health" -Method Get -TimeoutSec 10
    if ($health.ok -ne $true -or $health.data.status -cne "ok") {
      throw "Health response is not healthy."
    }
  } catch {
    throw "Cannot reach the configured Finwealth server at $($manifest.apiBase): $($_.Exception.Message)"
  }
}

if ($CheckOnly) {
  Write-Host "Remote client package and server connectivity checks passed."
  return
}

if ($manifest.endpointMode -ceq "fixed") {
  Write-Host "Starting Finwealth against $($manifest.apiBase)"
} else {
  Write-Host "Starting Finwealth; configure the HTTPS server in the app."
}
$client = Start-Process -FilePath $ClientExe -WorkingDirectory $InstallDir -PassThru
Wait-Process -Id $client.Id
