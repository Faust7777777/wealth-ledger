param(
  [int]$ServerPort = 19090,
  [int]$AgentPort = 19092,
  [int]$TimeoutSeconds = 240,
  [switch]$SkipFinancialSummary,
  [switch]$IncludeTextAttachment,
  [switch]$IncludeVisionAttachment,
  [switch]$CreateVisionDraft,
  [switch]$CreateHoldingSnapshot
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
$savedNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
$env:NO_PROXY = @("127.0.0.1", "localhost", "::1", $savedNoProxy) |
  Where-Object { $_ } |
  Select-Object -Unique |
  Join-String -Separator ","

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

function Get-ToolErrorCode([string]$Root, [string]$ToolName) {
  $toolResults = @()
  Get-ChildItem -LiteralPath $Root -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
    ForEach-Object {
      Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | ForEach-Object {
        try {
          $entry = $_ | ConvertFrom-Json
          if (
            $entry.message.role -eq "toolResult" -and
            $entry.message.toolName -eq $ToolName -and
            $entry.message.isError -eq $true
          ) {
            $toolResults += $entry.message
          }
        } catch {
          # Ignore unrelated or partially written JSONL lines.
        }
      }
    }
  $result = $toolResults | Select-Object -Last 1
  if (!$result) { return "unknown" }
  $text = @($result.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join " "
  $codeMatch = [regex]::Match($text, '"code"\s*:\s*"([a-z0-9_]+)"')
  if ($codeMatch.Success) { return $codeMatch.Groups[1].Value }
  $tokenMatch = [regex]::Match($text, '\b(?:finwealth|invalid|movement|agent)_[a-z0-9_]+\b')
  return $(if ($tokenMatch.Success) { $tokenMatch.Value } else { "unknown" })
}

function Get-ToolCallShape([string]$Root, [string]$ToolName, [string]$ExpectedAccountId) {
  $calls = @()
  Get-ChildItem -LiteralPath $Root -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
    ForEach-Object {
      Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | ForEach-Object {
        try {
          $entry = $_ | ConvertFrom-Json
          if ($entry.message.role -eq "assistant") {
            foreach ($part in @($entry.message.content)) {
              if ($part.type -eq "toolCall" -and $part.name -eq $ToolName) {
                $calls += $part.arguments
              }
            }
          }
        } catch {
          # Ignore unrelated or partially written JSONL lines.
        }
      }
    }
  $arguments = $calls | Select-Object -Last 1
  if (!$arguments) { return "no call arguments" }
  $entries = @($arguments.entries)
  $entryShapes = @($entries | ForEach-Object {
    "amount=$($_.amount),currency=$($_.currency),direction=$($_.direction),role=$($_.role),accountMatches=$($_.accountId -eq $ExpectedAccountId),instrument=$([bool]$_.instrumentId)"
  }) -join ";"
  return "type=$($arguments.type),occurredAt=$($arguments.occurredAt),entries=$($entries.Count)[$entryShapes]"
}

New-Item -ItemType Directory -Path $temp | Out-Null
$token = [Convert]::ToHexString(
  [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()

try {
  $attachmentModes = @(
    [bool]$IncludeTextAttachment,
    [bool]$IncludeVisionAttachment,
    [bool]$CreateHoldingSnapshot
  ) | Where-Object { $_ }
  if ($attachmentModes.Count -gt 1) {
    throw "Choose at most one real-model attachment smoke mode."
  }
  if ($CreateVisionDraft -and !$IncludeVisionAttachment) {
    throw "CreateVisionDraft requires IncludeVisionAttachment."
  }
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

  $visionAccountId = $null
  if ($CreateVisionDraft) {
    $accountBody = @{
      displayName = "Vision Smoke Wallet"
      accountType = "bank"
      defaultCurrency = "CNY"
      supportedCurrencies = @("CNY")
      includeInNetWorth = $true
      balanceMode = "cash_balance"
      openingBalances = @(
        @{ currency = "CNY"; amount = "100.00"; quality = "exact" }
      )
    } | ConvertTo-Json -Depth 8 -Compress
    $account = Invoke-RestMethod `
      -Method Post `
      -Uri "$apiBase/v1/accounts" `
      -Headers @{ "Idempotency-Key" = "real-smoke-vision-account" } `
      -ContentType "application/json" `
      -Body $accountBody
    $visionAccountId = $account.data.id
  }
  $holdingAccountId = $null
  if ($CreateHoldingSnapshot) {
    $accountBody = @{
      displayName = "Holding Snapshot Smoke Exchange"
      accountType = "exchange"
      defaultCurrency = "USDT"
      supportedCurrencies = @("USDT")
      includeInNetWorth = $true
      balanceMode = "holdings"
      openingBalances = @()
    } | ConvertTo-Json -Depth 8 -Compress
    $account = Invoke-RestMethod `
      -Method Post `
      -Uri "$apiBase/v1/accounts" `
      -Headers @{ "Idempotency-Key" = "real-smoke-holding-account" } `
      -ContentType "application/json" `
      -Body $accountBody
    $holdingAccountId = $account.data.id
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
  $attachmentIds = @()
  $attachmentMarker = "FINWEALTH_SMOKE_7Q9"
  if ($IncludeTextAttachment) {
    $csvPath = Join-Path $temp "workspace-smoke.csv"
    [IO.File]::WriteAllText(
      $csvPath,
      "date,merchant,amount,marker`n2026-07-28,Smoke,12.34,$attachmentMarker`n",
      [Text.UTF8Encoding]::new($false)
    )
    $http = [Net.Http.HttpClient]::new()
    $multipart = [Net.Http.MultipartFormDataContent]::new()
    $fileContent = [Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($csvPath))
    $fileContent.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("text/csv")
    $multipart.Add($fileContent, "file", "workspace-smoke.csv")
    $uploadRequest = [Net.Http.HttpRequestMessage]::new(
      [Net.Http.HttpMethod]::Post,
      "$apiBase/v1/agent/attachments"
    )
    $uploadRequest.Headers.Add("Idempotency-Key", "real-smoke-csv")
    $uploadRequest.Content = $multipart
    $uploadResponse = $http.Send($uploadRequest)
    if (!$uploadResponse.IsSuccessStatusCode) {
      throw "Text attachment upload failed with $([int]$uploadResponse.StatusCode)."
    }
    $upload = $uploadResponse.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    $attachmentIds = @($upload.data.id)
    $uploadResponse.Dispose()
    $uploadRequest.Dispose()
    $multipart.Dispose()
    $http.Dispose()
  } elseif ($IncludeVisionAttachment -or $CreateHoldingSnapshot) {
    Add-Type -AssemblyName System.Drawing
    $imageName = if ($CreateHoldingSnapshot) { "okx-holdings-smoke.png" } else { "vision-smoke.png" }
    $imagePath = Join-Path $temp $imageName
    $imageHeight = if ($CreateHoldingSnapshot) { 760 } else { 500 }
    $bitmap = [Drawing.Bitmap]::new(1200, $imageHeight)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $font = [Drawing.Font]::new("Arial", 48, [Drawing.FontStyle]::Bold)
    try {
      $graphics.Clear([Drawing.Color]::White)
      $smallFont = [Drawing.Font]::new("Arial", 30, [Drawing.FontStyle]::Regular)
      try {
        if ($CreateHoldingSnapshot) {
          $graphics.DrawString("OKX ASSET OVERVIEW", $font, [Drawing.Brushes]::Black, 40, 40)
          $graphics.DrawString("BTC    0.25000000", $smallFont, [Drawing.Brushes]::Black, 40, 180)
          $graphics.DrawString("ETH    3.20000000", $smallFont, [Drawing.Brushes]::Black, 40, 290)
          $graphics.DrawString("USDT   1250.000000", $smallFont, [Drawing.Brushes]::Black, 40, 400)
          $graphics.DrawString("SOL    5.50000000", $smallFont, [Drawing.Brushes]::Black, 40, 510)
          $graphics.DrawString("Snapshot 2026-07-31 09:30 UTC", $smallFont, [Drawing.Brushes]::Black, 40, 630)
        } else {
          $graphics.DrawString("FINWEALTH_VISION_8K2", $font, [Drawing.Brushes]::Black, 40, 60)
          $graphics.DrawString("TOTAL CNY 88.20", $font, [Drawing.Brushes]::Black, 40, 180)
          $graphics.DrawString(
            "MERCHANT TEST CAFE  2026-07-28 12:30",
            $smallFont,
            [Drawing.Brushes]::Black,
            40,
            310
          )
        }
      } finally {
        $smallFont.Dispose()
      }
      $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $font.Dispose()
      $graphics.Dispose()
      $bitmap.Dispose()
    }
    $http = [Net.Http.HttpClient]::new()
    $multipart = [Net.Http.MultipartFormDataContent]::new()
    $fileContent = [Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($imagePath))
    $fileContent.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("image/png")
    $multipart.Add($fileContent, "file", $imageName)
    $uploadRequest = [Net.Http.HttpRequestMessage]::new(
      [Net.Http.HttpMethod]::Post,
      "$apiBase/v1/agent/attachments"
    )
    $uploadKey = if ($CreateHoldingSnapshot) { "real-smoke-holding-image" } else { "real-smoke-vision" }
    $uploadRequest.Headers.Add("Idempotency-Key", $uploadKey)
    $uploadRequest.Content = $multipart
    $uploadResponse = $http.Send($uploadRequest)
    if (!$uploadResponse.IsSuccessStatusCode) {
      throw "Vision attachment upload failed with $([int]$uploadResponse.StatusCode)."
    }
    $upload = $uploadResponse.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    $attachmentIds = @($upload.data.id)
    $uploadResponse.Dispose()
    $uploadRequest.Dispose()
    $multipart.Dispose()
    $http.Dispose()
  }
  $prompt = if ($IncludeTextAttachment) {
    "请先用 read 工具读取所附 CSV，再调用 finwealth_query 查询 overview；最后只回复 CSV 的 marker 值和当前净资产。不要创建、提交或修改任何记录。"
  } elseif ($CreateHoldingSnapshot) {
    "这是 Holding Snapshot Smoke Exchange 的完整 OKX 持仓截图。先用 finwealth_query 查询 accounts、instruments 和 holdings；对截图里缺少标的的加密资产调用 finwealth_ensure_crypto_instruments，并使用返回的真实 instrumentId；然后把截图中的全部资产和当前总数量一次性调用 finwealth_propose_holding_snapshot，生成一个待审核持仓快照。不得确认、批准或采用报价。最后只说明已加入待确认。"
  } elseif ($CreateVisionDraft) {
    "这是一张需要入账的消费票据。先用 finwealth_query 查询 accounts，找到 Vision Smoke Wallet；识别图片后调用 finwealth_propose_movement 创建一条 CNY 支出待审核记录，金额、时间和商户按图片，图片时间按 Asia/Shanghai。资金从该账户流出。不要确认或批准。最后只说明已提交审核。"
  } elseif ($IncludeVisionAttachment) {
    "请查看所附图片，再调用 finwealth_query 查询 overview；最后只回复图片中的 marker、总额和当前净资产。不要创建、提交或修改任何记录。"
  } else {
    "请先调用 finwealth_query 查询 overview，然后只用一句中文说明查询到的当前净资产。不要创建、提交或修改任何记录。"
  }
  $messageBody = @{
    text = $prompt
    attachmentIds = $attachmentIds
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
  if ($IncludeTextAttachment -and $assistant.text -notmatch [regex]::Escape($attachmentMarker)) {
    throw "The real model response did not contain the CSV marker."
  }
  if (
    $IncludeVisionAttachment -and
    !$CreateVisionDraft -and
    ($assistant.text -notmatch "FINWEALTH_VISION_8K2" -or $assistant.text -notmatch "88\.20")
  ) {
    throw "The real model response did not contain the image marker and amount."
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
    ($IncludeTextAttachment -and $events -notmatch '"name":"read"') -or
    ($CreateVisionDraft -and $events -notmatch '"name":"finwealth_propose_movement"') -or
    ($CreateHoldingSnapshot -and $events -notmatch '"name":"finwealth_ensure_crypto_instruments"') -or
    ($CreateHoldingSnapshot -and $events -notmatch '"name":"finwealth_propose_holding_snapshot"') -or
    $events -notmatch "(?m)^event: run\.completed\r?$"
  ) {
    $eventNames = [regex]::Matches($events, "(?m)^event: ([a-z.]+)\r?$") |
      ForEach-Object { $_.Groups[1].Value } |
      Sort-Object -Unique
    $observed = if ($eventNames.Count) { $eventNames -join ", " } else { "none" }
    throw "SSE event set was incomplete; observed event types: $observed."
  }

  if ($CreateVisionDraft) {
    if (
      $events -notmatch '(?s)event: tool\.completed\r?\ndata: \{[^\r\n]*"name":"finwealth_propose_movement"[^\r\n]*"isError":false'
    ) {
      $toolCode = Get-ToolErrorCode $temp "finwealth_propose_movement"
      $toolShape = Get-ToolCallShape $temp "finwealth_propose_movement" $visionAccountId
      throw "The vision bill proposal tool did not complete successfully (code=$toolCode; $toolShape)."
    }
    $pending = Invoke-RestMethod -Uri "$apiBase/v1/ai/proposals/pending"
    $pendingCount = @($pending.data).Count
    if ($pendingCount -ne 1) {
      throw "Vision bill created $pendingCount pending review proposals instead of one."
    }
    $accountAfter = Invoke-RestMethod -Uri "$apiBase/v1/accounts/$visionAccountId"
    $cnyBalance = $accountAfter.data.cashBalances |
      Where-Object { $_.currency -eq "CNY" } |
      Select-Object -First 1
    if ($cnyBalance.amount -ne "100.00") {
      throw "Creating a vision draft changed the confirmed account balance."
    }
  }

  if ($CreateHoldingSnapshot) {
    foreach ($toolName in @(
      "finwealth_ensure_crypto_instruments",
      "finwealth_propose_holding_snapshot"
    )) {
      $escapedToolName = [regex]::Escape($toolName)
      if (
        $events -notmatch "(?s)event: tool\.completed\r?\ndata: \{[^\r\n]*`"name`":`"$escapedToolName`"[^\r\n]*`"isError`":false"
      ) {
        $toolCode = Get-ToolErrorCode $temp $toolName
        throw "The holding snapshot tool $toolName did not complete successfully (code=$toolCode)."
      }
    }
    $instruments = Invoke-RestMethod -Uri "$apiBase/v1/instruments"
    $symbols = @($instruments.data | ForEach-Object { $_.symbol })
    foreach ($expectedSymbol in @("BTC", "ETH", "USDT", "SOL")) {
      if ($expectedSymbol -notin $symbols) {
        throw "The holding snapshot run did not ensure $expectedSymbol."
      }
    }
    $holdings = Invoke-RestMethod `
      -Uri "$apiBase/v1/accounts/$holdingAccountId/holdings"
    if (@($holdings.data).Count -ne 0) {
      throw "The Agent changed confirmed holdings before review."
    }
    $pending = Invoke-RestMethod -Uri "$apiBase/v1/ai/proposals/pending"
    $groups = @(
      $pending.data | ForEach-Object { $_.atomicGroups } | Where-Object {
        $_.targetType -eq "holding" -and $_.targetId -eq $holdingAccountId
      }
    )
    if ($groups.Count -ne 1) {
      throw "The holding snapshot run created $($groups.Count) review groups instead of one."
    }
    if (@($groups[0].proposedMovements).Count -ne 4) {
      throw "The holding snapshot review group did not contain all four assets."
    }
    if (@($groups[0].proposedMovements | Where-Object {
      "holding_snapshot" -notin @($_.tags)
    }).Count -ne 0) {
      throw "The holding snapshot review group contained a non-snapshot movement."
    }
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
    $attachmentLabel = if ($IncludeTextAttachment) {
      ", workspace text attachment"
    } elseif ($CreateHoldingSnapshot) {
      ", reviewed multi-asset holding snapshot"
    } elseif ($IncludeVisionAttachment) {
      if ($CreateVisionDraft) { ", reviewed vision bill draft" } else { ", native vision attachment" }
    } else {
      ""
    }
    Write-Host "OK: real Pi model$attachmentLabel, finance tool, and SSE smoke passed."
  } else {
    $attachmentLabel = if ($IncludeTextAttachment) {
      ", workspace text attachment"
    } elseif ($CreateHoldingSnapshot) {
      ", reviewed multi-asset holding snapshot"
    } elseif ($IncludeVisionAttachment) {
      if ($CreateVisionDraft) { ", reviewed vision bill draft" } else { ", native vision attachment" }
    } else {
      ""
    }
    Write-Host "OK: real Pi model$attachmentLabel, finance tool, SSE, and financial summary smoke passed."
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
  if ($null -eq $savedNoProxy) {
    Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
  } else {
    $env:NO_PROXY = $savedNoProxy
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
