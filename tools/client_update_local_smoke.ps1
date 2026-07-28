$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = [System.IO.Path]::GetTempPath()
$temp = Join-Path $tempRoot "finwealth-client-update-$([Guid]::NewGuid().ToString('N'))"
$ledger = Join-Path $temp "ledger.json"
$updates = Join-Path $temp "updates"
$logs = Join-Path $temp "logs"
$artifact = Join-Path $temp "finwealth-smoke-1.1.0+2-android.apk"
$provenance = "$artifact.manifest.json"
$server = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
$process = $null
$savedEnvironment = @{}

function Set-SmokeEnvironment([string]$Name, [string]$Value) {
  if (!$savedEnvironment.ContainsKey($Name)) {
    $savedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
  }
  [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
}

try {
  New-Item -ItemType Directory -Path $temp, $logs | Out-Null
  & cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
  if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $server -PathType Leaf)) {
    throw "Rust server build failed."
  }
  & $server --init-ledger $ledger | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Test ledger initialization failed." }

  [System.IO.File]::WriteAllBytes($artifact, [Text.Encoding]::UTF8.GetBytes("client-update-smoke"))
  $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
  $manifest = [ordered]@{
    packageFormat = 3
    clientVersion = "1.1.0+2"
    versionName = "1.1.0"
    versionCode = 2
    createdAt = "2026-07-28T12:00:00Z"
    sourceCommit = "0123456789abcdef0123456789abcdef01234567"
    sourceDirty = $false
    dataSource = "api_remote"
    endpointMode = "runtime"
    apiBase = ""
    platform = "android"
    signing = "debug-self-use"
    networkPolicyVerified = $true
    apk = (Split-Path -Leaf $artifact)
    apkSizeBytes = (Get-Item -LiteralPath $artifact).Length
    apkSha256 = $sha
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($provenance, $manifest, [Text.UTF8Encoding]::new($false))
  & python (Join-Path $root "tools\publish_client_update.py") `
    $artifact $provenance --update-dir $updates --note "smoke"
  if ($LASTEXITCODE -ne 0) { throw "Test update publication failed." }

  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()
  $passwordHash = ("client-update-smoke-password" | & $server --hash-password-stdin).Trim()
  if ($LASTEXITCODE -ne 0 -or !$passwordHash.StartsWith('$argon2')) {
    throw "Test password hashing failed."
  }
  Set-SmokeEnvironment "FINWEALTH_REQUIRE_AUTH" "true"
  Set-SmokeEnvironment "FINWEALTH_AUTH_USERNAME" "smoke-owner"
  Set-SmokeEnvironment "FINWEALTH_AUTH_PASSWORD_HASH" $passwordHash
  Set-SmokeEnvironment "FINWEALTH_AUTH_PASSWORD" ""
  Set-SmokeEnvironment "FINWEALTH_ALLOWED_HOSTS" "127.0.0.1"
  Set-SmokeEnvironment "FINWEALTH_QUOTE_PROVIDER" "none"
  Set-SmokeEnvironment "FINWEALTH_CLIENT_UPDATE_DIR" $updates
  Set-SmokeEnvironment "FINWEALTH_RS_ADDR" "127.0.0.1:$port"
  $process = Start-Process -FilePath $server `
    -ArgumentList @("--ledger-path", $ledger) `
    -RedirectStandardOutput (Join-Path $logs "server.out.log") `
    -RedirectStandardError (Join-Path $logs "server.err.log") `
    -WindowStyle Hidden -PassThru

  $base = "http://127.0.0.1:$port"
  $ready = $false
  for ($attempt = 0; $attempt -lt 80; $attempt++) {
    if ($process.HasExited) { throw "Rust server exited during startup." }
    try {
      Invoke-RestMethod -Uri "$base/v1/health" -TimeoutSec 2 | Out-Null
      $ready = $true
      break
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
  if (!$ready) { throw "Rust server did not become ready." }

  try {
    Invoke-WebRequest -Uri "$base/v1/accounts" -TimeoutSec 5 | Out-Null
    throw "Protected ledger route unexpectedly allowed an anonymous request."
  } catch {
    if ([int]$_.Exception.Response.StatusCode -ne 401) { throw }
  }
  $latestResponse = Invoke-WebRequest `
    -Uri "$base/v1/client-updates/android/stable/latest" -TimeoutSec 5
  if ($latestResponse.StatusCode -ne 200 -or $latestResponse.Headers['Cache-Control'] -ne 'no-store') {
    throw "Anonymous latest-manifest response is invalid."
  }
  $latest = $latestResponse.Content | ConvertFrom-Json
  if ($latest.versionCode -ne 2 -or $latest.asset.sha256 -ne $sha) {
    throw "Published update manifest does not match the fixture."
  }
  $download = Join-Path $temp "downloaded.apk"
  $assetResponse = Invoke-WebRequest -Uri "$base$($latest.asset.url)" -OutFile $download -PassThru -TimeoutSec 10
  if (
    $assetResponse.StatusCode -ne 200 -or
    $assetResponse.Headers['Content-Type'] -ne 'application/vnd.android.package-archive' -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant() -ne $sha
  ) {
    throw "Streamed update artifact failed header or byte verification."
  }
  Write-Host "Client update local-server smoke passed."
} finally {
  if ($process -and !$process.HasExited) {
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
  }
  foreach ($entry in $savedEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
  }
  if (Test-Path -LiteralPath $temp) {
    $resolvedTemp = (Resolve-Path -LiteralPath $temp).Path
    $resolvedRoot = (Resolve-Path -LiteralPath $tempRoot).Path.TrimEnd('\') + '\'
    if (!$resolvedTemp.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        !(Split-Path -Leaf $resolvedTemp).StartsWith("finwealth-client-update-")) {
      throw "Refusing to remove unexpected smoke directory: $resolvedTemp"
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
