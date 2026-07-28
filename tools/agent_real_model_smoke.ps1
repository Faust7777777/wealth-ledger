param(
  [int]$ServerPort = 19090,
  [int]$AgentPort = 19092,
  [int]$TimeoutSeconds = 240,
  [switch]$SkipFinancialSummary
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$temp = Join-Path $tempRoot "finwealth-agent-real-smoke-$([Guid]::NewGuid().ToString('N'))"
$server = $null
$agent = $null
$sse = $null
$savedEnvironment = @{}
$sensitiveValues = @()

function Require-Environment([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name, "Process")
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Required environment variable $Name is not set."
  }
  return $value
}

function Wait-AgentMessage(
  [string]$BaseUrl,
  [string]$ConversationId,
  [string]$RunId,
  [int]$Timeout
) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Timeout)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $messages = Invoke-RestMethod `
      -Uri "$BaseUrl/v1/agent/conversations/$ConversationId/messages" `
      -TimeoutSec 5
    $message = $messages.data | Where-Object {
      $_.runId -eq $RunId -and $_.role -eq "assistant"
    } | Select-Object -First 1
    if ($message.status -eq "completed") { return $message }
    if ($message.status -eq "failed") {
      throw "Agent run failed with code $($message.errorCode)."
    }
    Start-Sleep -Milliseconds 200
  }
  throw "Agent run did not finish within $Timeout seconds."
}

function Redact([string]$Value) {
  $result = $Value
  foreach ($secret in $sensitiveValues) {
    if (![string]::IsNullOrEmpty($secret)) {
      $result = $result.Replace($secret, "[redacted]")
    }
  }
  return $result
}

function Get-AssistantDiagnostic([string]$Root) {
  $messages = @()
  Get-ChildItem -LiteralPath $Root -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
    ForEach-Object {
      Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | ForEach-Object {
        try {
          $entry = $_ | ConvertFrom-Json
          if ($entry.message.role -eq "assistant") { $messages += $entry.message }
        } catch {
          # Ignore unrelated or partially written JSONL lines.
        }
      }
    }
  $message = $messages | Select-Object -Last 1
  if (!$message) { return "no persisted assistant message" }
  $types = @($message.content | ForEach-Object { $_.type }) -join ","
  $errorText = if ($message.errorMessage) {
    "; error=" + (Redact ([string]$message.errorMessage))
  } else {
    ""
  }
  return "stopReason=$($message.stopReason); contentTypes=$types$errorText"
}

New-Item -ItemType Directory -Path $temp | Out-Null
$token = [Convert]::ToHexString(
  [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()

try {
  $apiKey = Require-Environment "LORE_LLM_API_KEY"
  $baseUrl = Require-Environment "LORE_LLM_BASE_URL"
  $modelId = Require-Environment "LORE_LLM_MODEL"
  $sensitiveValues = @($apiKey, $baseUrl, $modelId, $token)

  $modelsDirectory = Join-Path $temp "pi"
  New-Item -ItemType Directory -Path $modelsDirectory | Out-Null
  $models = @{
    providers = @{
      lore = @{
        baseUrl = $baseUrl.TrimEnd("/")
        api = "openai-completions"
        apiKey = '$LORE_LLM_API_KEY'
        authHeader = $true
        compat = @{
          supportsDeveloperRole = $false
          supportsReasoningEffort = $false
        }
        models = @(
          @{
            id = $modelId
            name = "LORE"
            input = @("text", "image")
            contextWindow = 128000
            maxTokens = 4096
          }
        )
      }
    }
  }
  [IO.File]::WriteAllText(
    (Join-Path $modelsDirectory "models.json"),
    ($models | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false)
  )

  $serverExecutable = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
  & cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed." }
  $agentExecutable = Join-Path $root "agent-service\dist\main.js"
  & npm --prefix (Join-Path $root "agent-service") run build --silent
  if ($LASTEXITCODE -ne 0) { throw "Agent TypeScript build failed." }

  @(
    "FINWEALTH_AGENT_BASE_URL",
    "FINWEALTH_AGENT_INTERNAL_TOKEN",
    "FINWEALTH_RS_ADDR",
    "FINWEALTH_AGENT_ADDR",
    "FINWEALTH_SERVER_BASE_URL",
    "FINWEALTH_AGENT_STATE_DIR",
    "PI_CODING_AGENT_DIR"
  ) | ForEach-Object {
    $savedEnvironment[$_] = [Environment]::GetEnvironmentVariable($_, "Process")
  }

  $env:FINWEALTH_AGENT_BASE_URL = "http://127.0.0.1:$AgentPort"
  $env:FINWEALTH_AGENT_INTERNAL_TOKEN = $token
  $env:FINWEALTH_RS_ADDR = "127.0.0.1:$ServerPort"
  $server = Start-Process `
    -FilePath $serverExecutable `
    -ArgumentList @("--ledger-path", (Join-Path $temp "ledger.json")) `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "server.out") `
    -RedirectStandardError (Join-Path $temp "server.err")

  $env:FINWEALTH_AGENT_ADDR = "127.0.0.1:$AgentPort"
  $env:FINWEALTH_SERVER_BASE_URL = "http://127.0.0.1:$ServerPort"
  $env:FINWEALTH_AGENT_STATE_DIR = Join-Path $temp "agent-state"
  $env:PI_CODING_AGENT_DIR = $modelsDirectory
  $agent = Start-Process `
    -FilePath "node" `
    -ArgumentList @($agentExecutable) `
    -WorkingDirectory (Join-Path $root "agent-service") `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "agent.out") `
    -RedirectStandardError (Join-Path $temp "agent.err")

  $apiBase = "http://127.0.0.1:$ServerPort"
  $status = $null
  for ($attempt = 0; $attempt -lt 100; $attempt += 1) {
    try {
      $status = Invoke-RestMethod -Uri "$apiBase/v1/agent/status" -TimeoutSec 2
      break
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
  if ($null -eq $status) { throw "Agent status did not become ready." }
  if ($status.data.configured -ne $true -or $status.data.modelCount -lt 1) {
    throw "Temporary Pi model configuration was not loaded."
  }

  $conversation = Invoke-RestMethod `
    -Method Post `
    -Uri "$apiBase/v1/agent/conversations" `
    -Headers @{ "Idempotency-Key" = "real-smoke-conversation" } `
    -ContentType "application/json" `
    -Body '{"title":"Real model smoke"}'
  $availableModels = Invoke-RestMethod -Uri "$apiBase/v1/agent/models"
  $loreModel = $availableModels.data |
    Where-Object { $_.provider -eq "lore" } |
    Select-Object -First 1
  if (!$loreModel) { throw "The temporary LORE model was not listed as available." }
  $selectModelBody = @{ modelId = $loreModel.id } | ConvertTo-Json -Compress
  $conversation = Invoke-RestMethod `
    -Method Patch `
    -Uri "$apiBase/v1/agent/conversations/$($conversation.data.id)" `
    -Headers @{ "Idempotency-Key" = "real-smoke-model" } `
    -ContentType "application/json" `
    -Body $selectModelBody
  $conversationId = $conversation.data.id
  $messageBody = @{
    text = "请先调用 finwealth_query 查询 overview，然后只用一句中文说明查询到的当前净资产。不要创建、提交或修改任何记录。"
    attachmentIds = @()
  } | ConvertTo-Json -Compress
  $accepted = Invoke-RestMethod `
    -Method Post `
    -Uri "$apiBase/v1/agent/conversations/$conversationId/messages" `
    -Headers @{ "Idempotency-Key" = "real-smoke-message" } `
    -ContentType "application/json" `
    -Body $messageBody

  $ssePath = Join-Path $temp "events.txt"
  $sse = Start-Process `
    -FilePath "curl.exe" `
    -ArgumentList @(
      "--silent", "--show-error", "--no-buffer",
      "--max-time", $TimeoutSeconds,
      "$apiBase/v1/agent/conversations/$conversationId/events?after=0"
    ) `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $ssePath `
    -RedirectStandardError (Join-Path $temp "sse.err")

  $assistant = Wait-AgentMessage $apiBase $conversationId $accepted.data.runId $TimeoutSeconds
  if ([string]::IsNullOrWhiteSpace($assistant.text)) {
    $diagnostic = Get-AssistantDiagnostic $temp
    throw "The real model completed without assistant text ($diagnostic)."
  }
  $eventDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 100
    $events = if (Test-Path -LiteralPath $ssePath) {
      Get-Content $ssePath -Raw
    } else {
      ""
    }
  } while (
    $events -notmatch "(?m)^event: run\.completed\r?$" -and
    [DateTimeOffset]::UtcNow -lt $eventDeadline
  )
  if ($sse -and !$sse.HasExited) { Stop-Process -Id $sse.Id -Force }
  $sse.WaitForExit()
  # Start-Process can lose the last redirected stdout blocks when a long-lived
  # curl process is killed. Reconnect after completion and let curl time out
  # normally so the retained SSE replay is flushed to disk in full.
  $replayPath = Join-Path $temp "events-replay.txt"
  $sse = Start-Process `
    -FilePath "curl.exe" `
    -ArgumentList @(
      "--silent", "--no-buffer",
      "--max-time", 2,
      "$apiBase/v1/agent/conversations/$conversationId/events?after=0"
    ) `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $replayPath `
    -RedirectStandardError (Join-Path $temp "sse-replay.err")
  $sse.WaitForExit()
  $events = Get-Content $replayPath -Raw
  if (
    $events -notmatch "(?m)^id: [0-9]+\r?$" -or
    $events -notmatch "(?m)^event: message\.delta\r?$" -or
    $events -notmatch "(?m)^event: tool\.started\r?$" -or
    $events -notmatch '"name":"finwealth_query"' -or
    $events -notmatch "(?m)^event: run\.completed\r?$"
  ) {
    $eventNames = [regex]::Matches($events, "(?m)^event: ([a-z.]+)\r?$") |
      ForEach-Object { $_.Groups[1].Value } |
      Sort-Object -Unique
    $observed = if ($eventNames.Count) { $eventNames -join ", " } else { "none" }
    throw "SSE event set was incomplete; observed event types: $observed."
  }

  if (!$SkipFinancialSummary) {
    $automationBody = @{
      kind = "financial_summary"
      intervalHours = 24
      enabled = $false
    } | ConvertTo-Json -Compress
    $automation = Invoke-RestMethod `
      -Method Post `
      -Uri "$apiBase/v1/agent/automations" `
      -Headers @{ "Idempotency-Key" = "real-smoke-summary-create" } `
      -ContentType "application/json" `
      -Body $automationBody
    $conversations = Invoke-RestMethod -Uri "$apiBase/v1/agent/conversations"
    $primary = $conversations.data | Where-Object { $_.isPrimary -eq $true } | Select-Object -First 1
    if (!$primary) { throw "Financial summary did not create or locate the primary conversation." }
    $primaryModelBody = @{ modelId = $loreModel.id } | ConvertTo-Json -Compress
    Invoke-RestMethod `
      -Method Patch `
      -Uri "$apiBase/v1/agent/conversations/$($primary.id)" `
      -Headers @{ "Idempotency-Key" = "real-smoke-summary-model" } `
      -ContentType "application/json" `
      -Body $primaryModelBody | Out-Null
    Invoke-RestMethod `
      -Method Post `
      -Uri "$apiBase/v1/agent/automations/$($automation.data.id)/run" `
      -Headers @{ "Idempotency-Key" = "real-smoke-summary-run" } `
      -ContentType "application/json" `
      -Body '{}' | Out-Null

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $summary = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
      $messages = Invoke-RestMethod `
        -Uri "$apiBase/v1/agent/conversations/$($primary.id)/messages" `
        -TimeoutSec 5
      $summary = $messages.data | Where-Object {
        $_.role -eq "assistant" -and $_.status -in @("completed", "failed")
      } | Select-Object -Last 1
      if ($summary) { break }
      Start-Sleep -Milliseconds 200
    }
    if (!$summary -or $summary.status -ne "completed" -or [string]::IsNullOrWhiteSpace($summary.text)) {
      $summaryCode = if ($summary.errorCode) { $summary.errorCode } else { "none" }
      throw "Financial summary did not complete with assistant text (code=$summaryCode)."
    }
  }

  if ($SkipFinancialSummary) {
    Write-Host "OK: real Pi model, finance tool, and SSE smoke passed."
  } else {
    Write-Host "OK: real Pi model, finance tool, SSE, and financial summary smoke passed."
  }
} catch {
  $assistantDiagnostic = Get-AssistantDiagnostic $temp
  if ($assistantDiagnostic -ne "no persisted assistant message") {
    Write-Warning ("assistant diagnostic: " + $assistantDiagnostic)
  }
  foreach ($logName in @("server.err", "agent.err", "sse.err", "sse-replay.err")) {
    $logPath = Join-Path $temp $logName
    if (Test-Path -LiteralPath $logPath) {
      $diagnostic = Get-Content -LiteralPath $logPath -Tail 20 | Out-String
      if (![string]::IsNullOrWhiteSpace($diagnostic)) {
        Write-Warning ("$logName`n" + (Redact $diagnostic.Trim()))
      }
    }
  }
  throw
} finally {
  if ($sse -and !$sse.HasExited) { Stop-Process -Id $sse.Id -Force }
  if ($agent -and !$agent.HasExited) { Stop-Process -Id $agent.Id -Force }
  if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force }
  foreach ($entry in $savedEnvironment.GetEnumerator()) {
    if ($null -eq $entry.Value) {
      Remove-Item "Env:$($entry.Key)" -ErrorAction SilentlyContinue
    } else {
      Set-Item "Env:$($entry.Key)" $entry.Value
    }
  }
  $resolvedTemp = [System.IO.Path]::GetFullPath($temp)
  if (
    $resolvedTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $resolvedTemp).StartsWith("finwealth-agent-real-smoke-") -and
    (Test-Path -LiteralPath $resolvedTemp)
  ) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
