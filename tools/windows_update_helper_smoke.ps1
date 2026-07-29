$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$helper = Join-Path $root "tools\windows_update_helper.ps1"
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "finwealth-windows-update-$([Guid]::NewGuid().ToString('N'))"
$oldLocalAppData = $env:LOCALAPPDATA

function Write-FakePackage([string]$Path, [string]$Marker) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $Path "finwealth.exe"), $Marker)
  [System.IO.File]::WriteAllText((Join-Path $Path "package-manifest.json"), '{}')
  [System.IO.File]::WriteAllText(
    (Join-Path $Path "Start-Finwealth.ps1"),
    'param([switch]$PackageIntegrityOnly); if (!$PackageIntegrityOnly) { exit 2 }; exit 0'
  )
}

try {
  $env:LOCALAPPDATA = Join-Path $temp "local"
  $cache = Join-Path $env:LOCALAPPDATA "Finwealth\updates"
  $install = Join-Path $temp "Finwealth"
  $payload = Join-Path $temp "payload"
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  Write-FakePackage $install "old"
  Write-FakePackage $payload "new"
  $archive = Join-Path $cache "finwealth-test.zip"
  Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $archive
  $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()

  & $helper -Archive $archive -InstallDir $install -ParentPid 0 `
    -ExpectedSha256 $sha -SkipParentWait -NoRelaunch
  if ((Get-Content -Raw -LiteralPath (Join-Path $install "finwealth.exe")) -cne "new") {
    throw "Windows update helper did not install the new package."
  }
  $backup = Join-Path $temp ".finwealth-previous"
  if ((Get-Content -Raw -LiteralPath (Join-Path $backup "finwealth.exe")) -cne "old") {
    throw "Windows update helper did not retain the previous package."
  }

  $unsafe = Join-Path $cache "unsafe.zip"
  Add-Type -AssemblyName System.IO.Compression
  $stream = [System.IO.File]::Open($unsafe, [System.IO.FileMode]::Create)
  try {
    $zip = [System.IO.Compression.ZipArchive]::new(
      $stream,
      [System.IO.Compression.ZipArchiveMode]::Create,
      $false
    )
    try {
      $null = $zip.CreateEntry("../escape.txt")
    } finally {
      $zip.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
  $unsafeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $unsafe).Hash.ToLowerInvariant()
  $failed = $false
  try {
    & $helper -Archive $unsafe -InstallDir $install -ParentPid 0 `
      -ExpectedSha256 $unsafeSha -SkipParentWait -NoRelaunch
  } catch {
    $failed = $true
  }
  if (!$failed) { throw "Windows update helper accepted a traversal entry." }
  if ((Get-Content -Raw -LiteralPath (Join-Path $install "finwealth.exe")) -cne "new") {
    throw "Rejected update changed the installed package."
  }
  Write-Host "Windows update helper smoke passed."
} finally {
  $env:LOCALAPPDATA = $oldLocalAppData
  if (Test-Path -LiteralPath $temp) {
    Remove-Item -LiteralPath $temp -Recurse -Force
  }
}

