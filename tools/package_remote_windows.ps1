param(
  [Parameter(Mandatory = $true)]
  [string]$ApiBase,
  [string]$OutputDir = "dist",
  [switch]$SkipBuild,
  [switch]$AllowDirtySource,
  [switch]$CheckReadinessOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$parsedApiBase = $null
$apiBaseIsValid = ![string]::IsNullOrWhiteSpace($ApiBase) -and
  [System.Uri]::TryCreate($ApiBase, [System.UriKind]::Absolute, [ref]$parsedApiBase) -and
  $parsedApiBase.Scheme -ceq "https" -and
  ![string]::IsNullOrWhiteSpace($parsedApiBase.Host) -and
  [string]::IsNullOrEmpty($parsedApiBase.UserInfo) -and
  $parsedApiBase.AbsolutePath -ceq "/" -and
  [string]::IsNullOrEmpty($parsedApiBase.Query) -and
  [string]::IsNullOrEmpty($parsedApiBase.Fragment)
if (!$apiBaseIsValid) {
  throw "-ApiBase must be an HTTPS origin without credentials, path, query, or fragment, for example https://api.example.com."
}
$ApiBase = $parsedApiBase.GetLeftPart([System.UriPartial]::Authority)

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$git = Get-Command git -ErrorAction Stop
$sourceCommit = (& $git.Source -C $Root rev-parse HEAD).Trim().ToLowerInvariant()
$sourceStatus = @(& $git.Source -C $Root status --porcelain)
$sourceDirty = $sourceStatus.Count -gt 0
if ($sourceDirty -and !$AllowDirtySource) {
  throw "Source worktree is dirty. Commit changes before creating a remote client package."
}
if ($sourceDirty -and $SkipBuild) {
  throw "-SkipBuild cannot verify a dirty source tree against existing binaries."
}

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
$flutterExe = if ($flutter) { $flutter.Source } else { Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat" }
if (!(Test-Path -LiteralPath $flutterExe -PathType Leaf)) {
  throw "flutter not found. Install Flutter or add it to PATH."
}

& $flutterExe test test\auth_client_test.dart test\api_remote_mode_test.dart
if ($LASTEXITCODE -ne 0) {
  throw "Remote auth/data-source readiness tests failed."
}
if ($CheckReadinessOnly) {
  Write-Host "Windows remote client readiness passed for $ApiBase."
  return
}

$versionLine = (Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern "^version:\s*(.+)$").Matches.Groups[1].Value.Trim()
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$packageName = "finwealth-$versionLine-$stamp-windows-server-client-x64"
$windowsRelease = Join-Path $Root "build\windows\x64\runner\Release"
$buildConfigPath = Join-Path $windowsRelease "finwealth.build-config.json"

if (!$SkipBuild) {
  & $flutterExe build windows `
    --dart-define=DATA_SOURCE=api_remote `
    --dart-define=API_BASE=$ApiBase
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter Windows remote client build failed."
  }
  $buildConfig = [ordered]@{
    buildFormat = 3
    dataSource = "api_remote"
    apiBase = $ApiBase
    serverBundled = $false
    clientVersion = $versionLine
    sourceCommit = $sourceCommit
    sourceDirty = $sourceDirty
    builtAt = (Get-Date).ToUniversalTime().ToString("o")
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($buildConfigPath, $buildConfig, [System.Text.UTF8Encoding]::new($false))
}

$buildConfig = Get-Content -Raw -LiteralPath $buildConfigPath | ConvertFrom-Json
if (
  $buildConfig.buildFormat -ne 3 -or
  $buildConfig.dataSource -cne "api_remote" -or
  $buildConfig.apiBase -cne $ApiBase -or
  $buildConfig.serverBundled -ne $false -or
  $buildConfig.clientVersion -cne $versionLine -or
  $buildConfig.sourceCommit -cne $sourceCommit -or
  $buildConfig.sourceDirty -ne $sourceDirty
) {
  throw "Existing Windows build does not match the requested remote server configuration."
}

$dist = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $Root $OutputDir }
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$stage = Join-Path $dist ".stage-$packageName"
if (Test-Path -LiteralPath $stage) {
  throw "Unexpected package staging collision: $stage"
}
New-Item -ItemType Directory -Path $stage | Out-Null
try {
  Copy-Item -Path (Join-Path $windowsRelease "*") -Destination $stage -Recurse
  Copy-Item -LiteralPath (Join-Path $Root "tools\windows_remote_launcher.ps1") -Destination (Join-Path $stage "Start-Finwealth.ps1")
  Copy-Item -LiteralPath (Join-Path $Root "tools\windows_remote_launcher.cmd") -Destination (Join-Path $stage "Start-Finwealth.cmd")
  Copy-Item -LiteralPath (Join-Path $Root "docs\deploy\WINDOWS_SERVER_CLIENT_PACKAGE.md") -Destination (Join-Path $stage "README.md")

  $client = Join-Path $stage "finwealth.exe"
  $launcherPs1 = Join-Path $stage "Start-Finwealth.ps1"
  $launcherCmd = Join-Path $stage "Start-Finwealth.cmd"
  $packagedBuildConfig = Join-Path $stage "finwealth.build-config.json"
  foreach ($required in @($client, $launcherPs1, $launcherCmd, $packagedBuildConfig)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Remote package input is missing: $required"
    }
  }

  $manifest = [ordered]@{
    packageFormat = 3
    clientVersion = $versionLine
    createdAt = (Get-Date).ToUniversalTime().ToString("o")
    sourceCommit = $sourceCommit
    sourceDirty = $sourceDirty
    dataSource = "api_remote"
    apiBase = $ApiBase
    client = "finwealth.exe"
    clientSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $client).Hash.ToLowerInvariant()
    launcherPowerShell = "Start-Finwealth.ps1"
    launcherPowerShellSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $launcherPs1).Hash.ToLowerInvariant()
    launcherCmd = "Start-Finwealth.cmd"
    launcherCmdSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $launcherCmd).Hash.ToLowerInvariant()
    buildConfig = "finwealth.build-config.json"
    buildConfigSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedBuildConfig).Hash.ToLowerInvariant()
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText((Join-Path $stage "package-manifest.json"), $manifest, [System.Text.UTF8Encoding]::new($false))

  & $launcherPs1 -PackageIntegrityOnly
  if ($LASTEXITCODE -ne 0) {
    throw "Staged remote client failed package integrity verification."
  }

  $zipPath = Join-Path $dist "$packageName.zip"
  if (Test-Path -LiteralPath $zipPath) {
    throw "Package already exists: $zipPath"
  }
  Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath
  $verify = Join-Path $dist ".verify-$packageName"
  try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $verify
    & (Join-Path $verify "Start-Finwealth.ps1") -PackageIntegrityOnly
    if ($LASTEXITCODE -ne 0) {
      throw "Archived remote client failed package integrity verification."
    }
  } finally {
    if (Test-Path -LiteralPath $verify) {
      Remove-Item -LiteralPath $verify -Recurse -Force
    }
  }
  $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
  "$zipHash  $(Split-Path -Leaf $zipPath)" | Set-Content -LiteralPath "$zipPath.sha256" -Encoding ASCII
  Write-Host "Windows server client package: $zipPath"
  Write-Host "Windows server client SHA-256: $zipHash"
} finally {
  if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
  }
}
