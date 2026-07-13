param(
  [string]$OutputDir = "dist",
  [string]$WindowsApiBase = "http://127.0.0.1:8791",
  [switch]$SkipBuild,
  [switch]$WindowsOnly,
  [switch]$AndroidOnly,
  [switch]$AndroidReadOnlyPreview,
  [switch]$CheckReadinessOnly,
  [switch]$AllowDirtySource
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($WindowsOnly -and $AndroidOnly) {
  throw "-WindowsOnly and -AndroidOnly cannot be used together."
}
if ($WindowsOnly -and $AndroidReadOnlyPreview) {
  throw "-WindowsOnly cannot be combined with -AndroidReadOnlyPreview."
}
if ($AndroidOnly -and !$AndroidReadOnlyPreview) {
  throw "Android writable data source is not decided. Pass -AndroidReadOnlyPreview to explicitly build a read-only preview APK."
}
$ParsedWindowsApiBase = $null
$ApiBaseIsValid = ![string]::IsNullOrWhiteSpace($WindowsApiBase) -and
  [System.Uri]::TryCreate(
    $WindowsApiBase,
    [System.UriKind]::Absolute,
    [ref]$ParsedWindowsApiBase
  ) -and
  $ParsedWindowsApiBase.Scheme -ceq "http" -and
  $ParsedWindowsApiBase.Host -ceq "127.0.0.1" -and
  $ParsedWindowsApiBase.Port -eq 8791 -and
  [string]::IsNullOrEmpty($ParsedWindowsApiBase.UserInfo) -and
  $ParsedWindowsApiBase.AbsolutePath -ceq "/" -and
  [string]::IsNullOrEmpty($ParsedWindowsApiBase.Query) -and
  [string]::IsNullOrEmpty($ParsedWindowsApiBase.Fragment)
if (!$ApiBaseIsValid) {
  throw "Windows self-use package API base must be exactly loopback HTTP on port 8791: http://127.0.0.1:8791."
}
$WindowsApiBase = $ParsedWindowsApiBase.GetLeftPart([System.UriPartial]::Authority)

$BuildWindows = !$AndroidOnly
$BuildAndroid = $AndroidReadOnlyPreview
if ($BuildAndroid -and $SkipBuild) {
  throw "-SkipBuild is not allowed for the Android read-only preview because a stale APK could be mislabeled."
}
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-FlutterExecutable {
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if ($flutter) {
    return $flutter.Source
  }
  $candidate = Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }
  throw "flutter not found. Install Flutter or add it to PATH."
}

function Assert-ClientIdempotencyReadiness {
  $clientSource = Join-Path $Root "lib\data\api_mock_repositories.dart"
  $testPath = Join-Path $Root "test\auth_client_test.dart"
  if (!(Test-Path -LiteralPath $clientSource -PathType Leaf) -or !(Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw "CLIENT_IDEMPOTENCY_BLOCKER: Flutter client source or auth client regression test is missing."
  }
  $clientText = Get-Content -Raw -LiteralPath $clientSource
  $testText = Get-Content -Raw -LiteralPath $testPath
  foreach ($required in @(
    "Idempotency-Key",
    "idempotencyKey: key",
    "method != 'GET'",
    "Random.secure()"
  )) {
    if (!$clientText.Contains($required)) {
      throw "CLIENT_IDEMPOTENCY_BLOCKER: Flutter client is missing required idempotency behavior marker: $required"
    }
  }
  foreach ($required in @(
    "write requests carry a 128-bit hex Idempotency-Key; GET does not",
    "two independent writes use different Idempotency-Keys",
    "401 replay reuses the same Idempotency-Key; auth refresh has none"
  )) {
    if (!$testText.Contains($required)) {
      throw "CLIENT_IDEMPOTENCY_BLOCKER: auth_client_test.dart is missing required behavior test: $required"
    }
  }

  $flutterExe = Resolve-FlutterExecutable
  & $flutterExe test $testPath
  if ($LASTEXITCODE -ne 0) {
    throw "CLIENT_IDEMPOTENCY_BLOCKER: auth client behavior tests failed."
  }
}

if ($BuildWindows) {
  Assert-ClientIdempotencyReadiness
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (!$git) {
  throw "git not found; package provenance cannot be recorded."
}
$SourceCommit = (& $git.Source -C $Root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
  throw "Unable to resolve the source Git commit."
}
$SourceStatus = @(& $git.Source -C $Root status --porcelain)
if ($LASTEXITCODE -ne 0) {
  throw "Unable to inspect the source Git worktree."
}
$SourceDirty = $SourceStatus.Count -gt 0
if ($SourceDirty -and !$AllowDirtySource) {
  throw "Source worktree is dirty. Commit/stash changes, or pass -AllowDirtySource for an explicitly non-release self-use build."
}
if ($SourceDirty -and $SkipBuild) {
  throw "-SkipBuild cannot verify dirty source against existing binaries. Rebuild without -SkipBuild."
}

if ($CheckReadinessOnly) {
  if (!$BuildWindows) {
    throw "-CheckReadinessOnly currently validates the paired Windows client/server package only."
  }
  Write-Host "Windows self-use package readiness passed."
  return
}

if ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $Dist = $OutputDir
} else {
  $Dist = Join-Path $Root $OutputDir
}
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

$FlutterExe = $null
if (!$SkipBuild) {
  $FlutterExe = Resolve-FlutterExecutable
}

$VersionLine = (Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern "^version:\s*(.+)$").Matches.Groups[1].Value.Trim()
$ServerVersion = (Select-String -Path (Join-Path $Root "server-rs\Cargo.toml") -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches.Groups[1].Value
if ([string]::IsNullOrWhiteSpace($VersionLine) -or [string]::IsNullOrWhiteSpace($ServerVersion)) {
  throw "Client or server version metadata is missing."
}
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$PackageName = "finwealth-$VersionLine-$Stamp"

if ($BuildWindows) {
  $ManifestPath = Join-Path $Root "server-rs\Cargo.toml"
  $ServerRelease = Join-Path $Root "server-rs\target\release\finwealth-server.exe"
  $WindowsRelease = Join-Path $Root "build\windows\x64\runner\Release"
  $BuildConfigPath = Join-Path $WindowsRelease "finwealth.build-config.json"

  if (!$SkipBuild) {
    $Cargo = Get-Command cargo -ErrorAction SilentlyContinue
    $CargoExe = if ($Cargo) { $Cargo.Source } else { Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe" }
    if (!(Test-Path $CargoExe)) {
      throw "cargo not found. Install Rust or add cargo.exe to PATH."
    }
    & $CargoExe build --manifest-path $ManifestPath --release
    if ($LASTEXITCODE -ne 0) {
      throw "Rust server release build failed."
    }
    & $FlutterExe build windows `
      --dart-define=DATA_SOURCE=local_server `
      --dart-define=API_BASE=$WindowsApiBase
    if ($LASTEXITCODE -ne 0) {
      throw "Flutter Windows self-use build failed."
    }
    $buildConfig = [ordered]@{
      buildFormat = 2
      dataSource = "local_server"
      apiBase = $WindowsApiBase
      serverBundled = $true
      clientVersion = $VersionLine
      serverVersion = $ServerVersion
      sourceCommit = $SourceCommit.ToLowerInvariant()
      sourceDirty = $SourceDirty
      builtAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($BuildConfigPath, $buildConfig, [System.Text.UTF8Encoding]::new($false))
  }

  foreach ($required in @(
    (Join-Path $WindowsRelease "finwealth.exe"),
    $ServerRelease,
    $BuildConfigPath,
    (Join-Path $Root "tools\windows_self_use_launcher.ps1"),
    (Join-Path $Root "tools\windows_self_use_launcher.cmd"),
    (Join-Path $Root "docs\deploy\WINDOWS_SELF_USE_PACKAGE.md")
  )) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Windows self-use package input is missing: $required"
    }
  }
  $buildConfig = Get-Content -Raw -LiteralPath $BuildConfigPath | ConvertFrom-Json
  if (
    $buildConfig.buildFormat -ne 2 -or
    $buildConfig.dataSource -ne "local_server" -or
    $buildConfig.apiBase -ne $WindowsApiBase -or
    $buildConfig.serverBundled -ne $true -or
    $buildConfig.clientVersion -ne $VersionLine -or
    $buildConfig.serverVersion -ne $ServerVersion -or
    ([string]$buildConfig.sourceCommit).ToLowerInvariant() -ne $SourceCommit.ToLowerInvariant() -or
    $buildConfig.sourceDirty -ne $SourceDirty
  ) {
    throw "Existing Windows build was not produced for the requested self-use local_server configuration. Re-run without -SkipBuild."
  }

  $Stage = Join-Path $Dist ".stage-$PackageName-windows-x64"
  if (Test-Path $Stage) {
    throw "Unexpected package staging collision: $Stage"
  }
  New-Item -ItemType Directory -Path $Stage | Out-Null
  try {
    Copy-Item -Path (Join-Path $WindowsRelease "*") -Destination $Stage -Recurse
    $ServerDir = Join-Path $Stage "server"
    New-Item -ItemType Directory -Path $ServerDir | Out-Null
    Copy-Item -LiteralPath $ServerRelease -Destination (Join-Path $ServerDir "finwealth-server.exe")
    Copy-Item -LiteralPath (Join-Path $Root "tools\windows_self_use_launcher.ps1") -Destination (Join-Path $Stage "Start-Finwealth.ps1")
    Copy-Item -LiteralPath (Join-Path $Root "tools\windows_self_use_launcher.cmd") -Destination (Join-Path $Stage "Start-Finwealth.cmd")
    Copy-Item -LiteralPath (Join-Path $Root "docs\deploy\WINDOWS_SELF_USE_PACKAGE.md") -Destination (Join-Path $Stage "README.md")

    $packagedClient = Join-Path $Stage "finwealth.exe"
    $packagedServer = Join-Path $ServerDir "finwealth-server.exe"
    $packagedLauncherPs1 = Join-Path $Stage "Start-Finwealth.ps1"
    $packagedLauncherCmd = Join-Path $Stage "Start-Finwealth.cmd"
    $packagedBuildConfig = Join-Path $Stage "finwealth.build-config.json"
    $clientHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedClient).Hash.ToLowerInvariant()
    $serverHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedServer).Hash.ToLowerInvariant()
    $launcherPs1Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedLauncherPs1).Hash.ToLowerInvariant()
    $launcherCmdHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedLauncherCmd).Hash.ToLowerInvariant()
    $buildConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedBuildConfig).Hash.ToLowerInvariant()
    $packageManifest = [ordered]@{
      packageFormat = 2
      clientVersion = $VersionLine
      serverVersion = $ServerVersion
      createdAt = (Get-Date).ToUniversalTime().ToString("o")
      sourceCommit = $SourceCommit.ToLowerInvariant()
      sourceDirty = $SourceDirty
      dataSource = "local_server"
      apiBase = $WindowsApiBase
      client = "finwealth.exe"
      clientSha256 = $clientHash
      server = "server/finwealth-server.exe"
      serverSha256 = $serverHash
      launcherPowerShell = "Start-Finwealth.ps1"
      launcherPowerShellSha256 = $launcherPs1Hash
      launcherCmd = "Start-Finwealth.cmd"
      launcherCmdSha256 = $launcherCmdHash
      buildConfig = "finwealth.build-config.json"
      buildConfigSha256 = $buildConfigHash
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText(
      (Join-Path $Stage "package-manifest.json"),
      $packageManifest,
      [System.Text.UTF8Encoding]::new($false)
    )

    & $packagedLauncherPs1 -PackageIntegrityOnly
    if ($LASTEXITCODE -ne 0) {
      throw "Staged Windows package failed launcher integrity check."
    }

    $ZipPath = Join-Path $Dist "$PackageName-windows-self-use-x64.zip"
    if (Test-Path $ZipPath) {
      throw "Package already exists: $ZipPath"
    }
    Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath
    $VerifyDir = Join-Path $Dist ".verify-$PackageName-windows-x64"
    try {
      Expand-Archive -LiteralPath $ZipPath -DestinationPath $VerifyDir
      & (Join-Path $VerifyDir "Start-Finwealth.ps1") -PackageIntegrityOnly
      if ($LASTEXITCODE -ne 0) {
        throw "Archived Windows package failed launcher integrity check."
      }
    } finally {
      if (Test-Path -LiteralPath $VerifyDir) {
        Remove-Item -LiteralPath $VerifyDir -Recurse -Force
      }
    }
    $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
    "$zipHash  $(Split-Path -Leaf $ZipPath)" | Set-Content -LiteralPath "$ZipPath.sha256" -Encoding ASCII
    Write-Host "Windows self-use package: $ZipPath"
    Write-Host "Windows self-use package SHA-256: $ZipPath.sha256"
  } finally {
    if (Test-Path $Stage) {
      Remove-Item -LiteralPath $Stage -Recurse -Force
    }
  }
}

if ($BuildAndroid) {
  Write-Warning "Android writable storage/sync direction is not decided. Building an explicitly read-only preview APK."
  if (!$SkipBuild) {
    & $FlutterExe build apk --debug
    if ($LASTEXITCODE -ne 0) {
      throw "Flutter Android preview build failed."
    }
  }
  $ApkSource = Join-Path $Root "build\app\outputs\flutter-apk\app-debug.apk"
  if (!(Test-Path $ApkSource)) {
    throw "Android debug APK not found: $ApkSource"
  }
  $ApkTarget = Join-Path $Dist "$PackageName-android-readonly-preview-debug.apk"
  Copy-Item -LiteralPath $ApkSource -Destination $ApkTarget
  $apkHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ApkTarget).Hash.ToLowerInvariant()
  "$apkHash  $(Split-Path -Leaf $ApkTarget)" | Set-Content -LiteralPath "$ApkTarget.sha256" -Encoding ASCII
  Write-Host "Android read-only preview package: $ApkTarget"
  Write-Host "Android read-only preview SHA-256: $ApkTarget.sha256"
}
