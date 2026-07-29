param(
  [Parameter(Mandatory = $true)][string]$Archive,
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$ExpectedSha256,
  [switch]$NoRelaunch,
  [switch]$SkipParentWait
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string]$Message) {
  throw "Finwealth update failed: $Message"
}

if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
  Fail "invalid expected SHA-256"
}
if (!$env:LOCALAPPDATA) {
  Fail "LOCALAPPDATA is unavailable"
}

$cacheRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Finwealth\updates"))
$archivePath = [System.IO.Path]::GetFullPath($Archive)
$archiveParent = [System.IO.Path]::GetDirectoryName($archivePath)
if (
  ![System.IO.File]::Exists($archivePath) -or
  ![string]::Equals($archiveParent, $cacheRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
  [System.IO.Path]::GetExtension($archivePath) -cne ".zip"
) {
  Fail "archive is outside the controlled update cache"
}
$actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
if (![string]::Equals($actualSha, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
  Fail "archive SHA-256 mismatch"
}

$target = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$targetRoot = [System.IO.Path]::GetPathRoot($target).TrimEnd('\')
if (
  [string]::Equals($target, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
  ![System.IO.File]::Exists((Join-Path $target "finwealth.exe")) -or
  ![System.IO.File]::Exists((Join-Path $target "package-manifest.json"))
) {
  Fail "install directory is not a Finwealth package"
}

$parent = [System.IO.Directory]::GetParent($target)
if ($null -eq $parent) { Fail "install directory has no parent" }
$nonce = [Guid]::NewGuid().ToString('N')
$stage = Join-Path $parent.FullName ".finwealth-update-$nonce"
$backup = Join-Path $parent.FullName ".finwealth-previous"
[System.IO.Directory]::CreateDirectory($stage) | Out-Null

try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    $stagePrefix = [System.IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
    foreach ($entry in $zip.Entries) {
      $name = [string]$entry.FullName
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $normalized = $name.Replace('/', '\')
      if (
        [System.IO.Path]::IsPathRooted($normalized) -or
        $normalized.Contains(':') -or
        ($normalized -split '\\') -contains '..'
      ) {
        Fail "archive contains an unsafe path"
      }
      $destination = [System.IO.Path]::GetFullPath((Join-Path $stage $normalized))
      if (!$destination.StartsWith($stagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "archive entry escaped the staging directory"
      }
    }
  } finally {
    $zip.Dispose()
  }
  [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $stage)

  $integrityScript = Join-Path $stage "Start-Finwealth.ps1"
  if (![System.IO.File]::Exists($integrityScript)) {
    Fail "updated package has no integrity launcher"
  }
  & $integrityScript -PackageIntegrityOnly
  if ($LASTEXITCODE -ne 0) { Fail "updated package integrity check failed" }

  if (!$SkipParentWait -and $ParentPid -gt 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
      if ([DateTime]::UtcNow -ge $deadline) {
        Fail "Finwealth did not exit before update"
      }
      Start-Sleep -Milliseconds 200
    }
  }

  if ([System.IO.Directory]::Exists($backup)) {
    [System.IO.Directory]::Delete($backup, $true)
  }
  [System.IO.Directory]::Move($target, $backup)
  try {
    [System.IO.Directory]::Move($stage, $target)
    if (![System.IO.File]::Exists((Join-Path $target "finwealth.exe"))) {
      Fail "updated executable is missing after replacement"
    }
    if (!$NoRelaunch) {
      Start-Process -FilePath (Join-Path $target "finwealth.exe") -WorkingDirectory $target
    }
  } catch {
    if ([System.IO.Directory]::Exists($target)) {
      [System.IO.Directory]::Delete($target, $true)
    }
    [System.IO.Directory]::Move($backup, $target)
    throw
  }
} finally {
  if ([System.IO.Directory]::Exists($stage)) {
    [System.IO.Directory]::Delete($stage, $true)
  }
}
