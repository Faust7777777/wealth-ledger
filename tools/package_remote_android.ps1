param(
  [string]$ApiBase = "",
  [string]$OutputDir = "dist",
  [switch]$AllowDirtySource,
  [switch]$CheckReadinessOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$EndpointMode = if ([string]::IsNullOrWhiteSpace($ApiBase)) { "runtime" } else { "fixed" }
if ($EndpointMode -eq "fixed") {
  $parsedApiBase = $null
  $valid = [System.Uri]::TryCreate($ApiBase, [System.UriKind]::Absolute, [ref]$parsedApiBase) -and
    $parsedApiBase.Scheme -ceq "https" -and
    ![string]::IsNullOrWhiteSpace($parsedApiBase.Host) -and
    [string]::IsNullOrEmpty($parsedApiBase.UserInfo) -and
    $parsedApiBase.AbsolutePath -ceq "/" -and
    [string]::IsNullOrEmpty($parsedApiBase.Query) -and
    [string]::IsNullOrEmpty($parsedApiBase.Fragment)
  if (!$valid) {
    throw "-ApiBase must be an HTTPS origin without credentials, path, query, or fragment."
  }
  $ApiBase = $parsedApiBase.GetLeftPart([System.UriPartial]::Authority)
} else {
  $ApiBase = ""
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$git = Get-Command git -ErrorAction Stop
$sourceCommit = (& $git.Source -C $Root rev-parse HEAD).Trim().ToLowerInvariant()
$sourceStatus = @(& $git.Source -C $Root status --porcelain)
$sourceDirty = $sourceStatus.Count -gt 0
if ($sourceDirty -and !$AllowDirtySource) {
  throw "Source worktree is dirty. Commit changes before creating an Android server client."
}

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
$flutterExe = if ($flutter) {
  $flutter.Source
} elseif ($IsWindows -and $env:USERPROFILE) {
  Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat"
} else {
  $null
}
if (!$flutterExe -or !(Test-Path -LiteralPath $flutterExe -PathType Leaf)) {
  throw "flutter not found. Install Flutter or add it to PATH."
}

$readinessTests = @(
  (Join-Path $Root "test/auth_client_test.dart"),
  (Join-Path $Root "test/api_remote_mode_test.dart"),
  (Join-Path $Root "test/remote_server_setup_test.dart")
)
& $flutterExe test @readinessTests
if ($LASTEXITCODE -ne 0) {
  throw "Android remote auth/data-source readiness tests failed."
}
if ($CheckReadinessOnly) {
  Write-Host "Android server client readiness passed (endpoint mode: $EndpointMode)."
  return
}

& $flutterExe build apk --debug `
  --dart-define=DATA_SOURCE=api_remote `
  --dart-define=API_BASE=$ApiBase
if ($LASTEXITCODE -ne 0) {
  throw "Flutter Android server client build failed."
}

$versionLine = (Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern "^version:\s*(.+)$").Matches.Groups[1].Value.Trim()
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dist = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $Root $OutputDir }
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$source = Join-Path $Root "build/app/outputs/flutter-apk/app-debug.apk"
if (!(Test-Path -LiteralPath $source -PathType Leaf)) {
  throw "Android debug APK was not produced."
}
$apkAnalyzer = Get-Command apkanalyzer -ErrorAction SilentlyContinue
$apkAnalyzerPath = if ($apkAnalyzer) { $apkAnalyzer.Source } else { $null }
if (!$apkAnalyzerPath) {
  $sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }
  $candidate = if (!$sdkRoot) {
    $null
  } elseif ($IsWindows) {
    Join-Path $sdkRoot "cmdline-tools/latest/bin/apkanalyzer.bat"
  } else {
    Join-Path $sdkRoot "cmdline-tools/latest/bin/apkanalyzer"
  }
  if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    $apkAnalyzerPath = $candidate
  }
}
if (!$apkAnalyzerPath) {
  throw "apkanalyzer not found; packaged Android network policy cannot be verified."
}
$permissions = (& $apkAnalyzerPath manifest permissions $source) -join "`n"
$compiledManifest = (& $apkAnalyzerPath manifest print $source) -join "`n"
if ($LASTEXITCODE -ne 0 -or $permissions -notmatch "android.permission.INTERNET") {
  throw "Packaged Android client is missing INTERNET permission."
}
if (
  $compiledManifest -notmatch 'android:usesCleartextTraffic="false"' -or
  $compiledManifest -notmatch 'android:allowBackup="false"'
) {
  throw "Packaged Android client does not enforce the reviewed network/backup policy."
}
$target = Join-Path $dist "finwealth-$versionLine-$stamp-android-server-client-debug.apk"
Copy-Item -LiteralPath $source -Destination $target
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
"$sha  $(Split-Path -Leaf $target)" | Set-Content -LiteralPath "$target.sha256" -Encoding ASCII
$manifest = [ordered]@{
  packageFormat = 3
  clientVersion = $versionLine
  createdAt = (Get-Date).ToUniversalTime().ToString("o")
  sourceCommit = $sourceCommit
  sourceDirty = $sourceDirty
  dataSource = "api_remote"
  endpointMode = $EndpointMode
  apiBase = $ApiBase
  platform = "android"
  signing = "debug-self-use"
  networkPolicyVerified = $true
  apk = (Split-Path -Leaf $target)
  apkSha256 = $sha
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText("$target.manifest.json", $manifest, [System.Text.UTF8Encoding]::new($false))
Write-Host "Android server client package: $target"
Write-Host "Android server client SHA-256: $sha"
