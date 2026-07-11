param(
  [string]$OutputDir = "dist",
  [string]$WindowsApiBase = "http://127.0.0.1:8791",
  [switch]$SkipBuild,
  [switch]$WindowsOnly,
  [switch]$AndroidOnly,
  [switch]$AndroidReadOnlyPreview
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
if ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $Dist = $OutputDir
} else {
  $Dist = Join-Path $Root $OutputDir
}
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

$FlutterExe = $null
if (!$SkipBuild) {
  $Flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if (!$Flutter) {
    $candidate = Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat"
    if (Test-Path $candidate) {
      $FlutterExe = $candidate
    } else {
      throw "flutter not found. Install Flutter or add it to PATH."
    }
  } else {
    $FlutterExe = $Flutter.Source
  }
}

$VersionLine = (Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern "^version:\s*(.+)$").Matches.Groups[1].Value.Trim()
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
      dataSource = "local_server"
      apiBase = $WindowsApiBase
      serverBundled = $true
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
  if ($buildConfig.dataSource -ne "local_server" -or $buildConfig.apiBase -ne $WindowsApiBase -or $buildConfig.serverBundled -ne $true) {
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

    $serverHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ServerRelease).Hash.ToLowerInvariant()
    $packageManifest = [ordered]@{
      packageFormat = 1
      version = $VersionLine
      createdAt = (Get-Date).ToUniversalTime().ToString("o")
      dataSource = "local_server"
      apiBase = $WindowsApiBase
      server = "server/finwealth-server.exe"
      serverSha256 = $serverHash
      launcher = "Start-Finwealth.cmd"
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText(
      (Join-Path $Stage "package-manifest.json"),
      $packageManifest,
      [System.Text.UTF8Encoding]::new($false)
    )

    $ZipPath = Join-Path $Dist "$PackageName-windows-self-use-x64.zip"
    if (Test-Path $ZipPath) {
      throw "Package already exists: $ZipPath"
    }
    Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath
    Write-Host "Windows self-use package: $ZipPath"
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
  Write-Host "Android read-only preview package: $ApkTarget"
}
