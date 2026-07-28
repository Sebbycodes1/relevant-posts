[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$LookbackHours = 24,

    [ValidateRange(1, 30)]
    [int]$MaxSignals = 20,

    [string]$Model = "grok-4.5"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot "outputs\live-x-feed.json"
. (Join-Path $PSScriptRoot "xai-key.ps1")

$coreHandles = @("ArtificialAnlys", "EpochAIResearch", "SemiAnalysis_", "interconnectsai", "AnthropicAI", "simonw")
$contextHandles = @(
    "karpathy",
    "JesseJenkins",
    "steipete",
    "OfficialLoganK",
    "AndrewYNg",
    "demishassabis",
    "drfeifei",
    "Thom_Wolf",
    "erikbryn",
    "tunguz"
)
$eventGatedHandles = @(
    "TechInsightsInc",
    "OpenAI",
    "GoogleDeepMind",
    "AIatMeta",
    "nvidia",
    "AMD",
    "MicronTech",
    "GoogleAI",
    "xai",
    "midjourney",
    "MIT_CSAIL",
    "IBMData",
    "sama",
    "gdb"
)
$sourcePerformancePath = Join-Path $projectRoot "work\x-source-performance.json"
if (Test-Path -LiteralPath $sourcePerformancePath) {
    try {
        $sourcePerformanceData = [IO.File]::ReadAllText($sourcePerformancePath) | ConvertFrom-Json
        $promotedHandles = @($sourcePerformanceData |
            Where-Object { [int]$_.acceptedCount -ge 2 -and [double]$_.averageScore -ge 72 } |
            ForEach-Object { ([string]$_.handle).Trim().TrimStart('@') } |
            Where-Object { $_ } |
            Select-Object -First 10)
        $contextHandles = @($contextHandles + $promotedHandles | Select-Object -Unique)
    } catch {}
}
$handles = @($coreHandles + $contextHandles + $eventGatedHandles | Select-Object -Unique)
$tierByHandle = @{}
foreach ($handle in $coreHandles) { $tierByHandle[$handle.ToLowerInvariant()] = "core" }
foreach ($handle in $contextHandles) { $tierByHandle[$handle.ToLowerInvariant()] = "context" }
foreach ($handle in $eventGatedHandles) { $tierByHandle[$handle.ToLowerInvariant()] = "event_gated" }

$now = Get-Date
$fromTime = $now.AddHours(-$LookbackHours)
$fromDate = $fromTime.ToString("yyyy-MM-dd")
$toDate = $now.ToString("yyyy-MM-dd")
$nowIso = $now.ToUniversalTime().ToString("o")
$candidateLimit = [Math]::Min(30, [Math]::Max(15, $MaxSignals * 2))

$prompt = @"
You are the intake editor for an institutional asset-management AI intelligence feed.

Search X only within the allowed handles supplied to the x_search tool. Find posts published after $($fromTime.ToUniversalTime().ToString("o")) and before $nowIso. Return up to $candidateLimit plausible candidates scoring at least 40 so the local policy layer can audit both admissions and rejections. Inspect every supplied handle and use multiple keyword, semantic and thread searches where needed; do not stop after the first few accounts produce results. For only the most material candidate claims, use no more than two Web Search calls in total to look for genuinely independent corroboration.

Cover material developments across AI labs, models, memory, semiconductors, chips, hardware, energy, datacenters, hyperscalers, software and policy. Exclude routine promotion, recycled news, engagement bait, personality drama, vague claims, ordinary replies and reposts without new information. Deduplicate multiple posts about the same underlying event; retain the most primary and informative post.

Apply this audited source policy without changing the content score itself:
- Core handles ($($coreHandles -join ', ')): search continuously, but admit only posts that clear the normal 55-point intake floor.
- Context handles ($($contextHandles -join ', ')): identify evidence-led analysis as well as exceptional commentary. The local policy layer admits corroborated or primary evidence-led analysis from 60, while pure commentary still requires 70.
- Event-gated handles ($($eventGatedHandles -join ', ')): admit only primary, material announcements or research such as model releases, specifications, deployments, investments, filings, customer wins or policy disclosures. Exclude partnerships without new substance, event promotion, recruiting, lifestyle content and generic brand claims.

Every item must correspond to a real X post found by the search tool and must include its direct https://x.com/.../status/... URL. Never invent a post, URL, quotation, metric or confirmation. If nothing clears the standard, return an empty signals array.

Score the POST, not the author's fame, on a conservative 100-point rubric:
- Significance, 0-40: measurable change to products, capabilities, economics, capacity, regulation or competitive positioning.
- Credibility, 0-25: primary evidence, specificity, track record and independent corroboration.
- Timeliness, 0-20: value from receiving the post now rather than later.
- Analytical depth, 0-15: mechanisms, quantification and explanatory value.

The total score must equal the four components. Use 90+ only for rare, verified developments with measurable first-order consequences and independent confirmation. Apply these hard caps: rumor <=59; an item with neither primary evidence nor independent confirmation <=69; commentary without a new event <=74; analysis without primary evidence <=79. Return plausible 40+ candidates for local audit rather than silently dropping borderline items.

Write a neutral title and factual summary. The implication must point to the analyst question, not make an investment recommendation. Use one or more sectors from: Labs, Models, Memory, Chips, Semis, Hardware, Energy, Datacenters, Hyperscalers, Software, Policy, Networking, Cloud.

For PM triage, also provide:
- eventKey: a concise lowercase canonical key for the underlying event, not the wording of this post.
- eventType: one of model_release, corporate, research, policy, infrastructure, supply_chain, earnings, commentary, other.
- entities: explicitly named companies, laboratories or issuers only; include a public ticker when unambiguous.
- whyNow: one sentence stating what is newly knowable today.
- evidenceSummary: one sentence describing the strongest evidence and its principal limitation.
- corroboratingUrls: up to three direct HTTPS URLs from independent sources. Do not include the original X URL or another account repeating the same source. Set hasIndependentConfirmation true only when this list contains real independent corroboration.
"@

$signalProperties = [ordered]@{
    eventKey = @{ type = "string" }
    id = @{ type = "string" }
    source = @{ type = "string" }
    handle = @{ type = "string" }
    platform = @{ type = "string"; enum = @("X") }
    age = @{ type = "string" }
    publishedAt = @{ type = "string" }
    score = @{ type = "integer"; minimum = 0; maximum = 100 }
    title = @{ type = "string" }
    summary = @{ type = "string" }
    implication = @{ type = "string" }
    sectors = @{ type = "array"; items = @{ type = "string" }; minItems = 1; maxItems = 6 }
    significance = @{ type = "integer"; minimum = 0; maximum = 40 }
    credibility = @{ type = "integer"; minimum = 0; maximum = 25 }
    timeliness = @{ type = "integer"; minimum = 0; maximum = 20 }
    depth = @{ type = "integer"; minimum = 0; maximum = 15 }
    postType = @{ type = "string"; enum = @("announcement", "research", "analysis", "commentary", "rumor") }
    eventType = @{ type = "string"; enum = @("model_release", "corporate", "research", "policy", "infrastructure", "supply_chain", "earnings", "commentary", "other") }
    entities = @{ type = "array"; items = @{ type = "string" }; maxItems = 8 }
    whyNow = @{ type = "string" }
    evidenceSummary = @{ type = "string" }
    corroboratingUrls = @{ type = "array"; items = @{ type = "string" }; maxItems = 3 }
    hasPrimaryEvidence = @{ type = "boolean" }
    hasIndependentConfirmation = @{ type = "boolean" }
    hasMeasurableFirstOrderImpact = @{ type = "boolean" }
    url = @{ type = "string" }
}

$signalRequired = @($signalProperties.Keys)
$schema = [ordered]@{
    type = "object"
    properties = [ordered]@{
        generatedAt = @{ type = "string" }
        signals = @{
            type = "array"
            maxItems = $candidateLimit
            items = [ordered]@{
                type = "object"
                properties = $signalProperties
                required = $signalRequired
                additionalProperties = $false
            }
        }
    }
    required = @("generatedAt", "signals")
    additionalProperties = $false
}

$requestBody = [ordered]@{
    model = $Model
    input = $prompt
    tools = @(
        [ordered]@{
            type = "x_search"
            allowed_x_handles = @()
            from_date = $fromDate
            to_date = $toDate
            enable_image_understanding = $true
        },
        [ordered]@{ type = "web_search" }
    )
    max_turns = 6
    text = [ordered]@{
        format = [ordered]@{
            type = "json_schema"
            name = "signal_desk_feed"
            schema = $schema
            strict = $true
        }
    }
    max_output_tokens = 10000
    store = $false
}

$handleBatches = @()
for ($offset = 0; $offset -lt $handles.Count; $offset += 10) {
    $lastIndex = [Math]::Min($offset + 9, $handles.Count - 1)
    $handleBatches += ,@($handles[$offset..$lastIndex])
}

$responses = @()
$apiKey = Get-XaiApiKey -ProjectRoot $projectRoot

try {
    $headers = @{ Authorization = "Bearer $apiKey" }
    for ($batchIndex = 0; $batchIndex -lt $handleBatches.Count; $batchIndex++) {
        $batchHandles = @($handleBatches[$batchIndex])
        $requestBody.input = "$prompt`n`nThis is search pass $($batchIndex + 1) of $($handleBatches.Count). Search only these handles in this pass: $($batchHandles -join ', ')."
        $requestBody.tools[0].allowed_x_handles = $batchHandles
        $bodyJson = $requestBody | ConvertTo-Json -Depth 30 -Compress

        Write-Host "Searching curated X accounts - pass $($batchIndex + 1) of $($handleBatches.Count)..." -ForegroundColor Cyan
        $responses += Invoke-RestMethod `
            -Method Post `
            -Uri "https://api.x.ai/v1/responses" `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $bodyJson `
            -TimeoutSec 300
    }
}
catch {
    $status = $_.Exception.Response.StatusCode.value__ 2>$null
    if ($status) {
        $detail = $_.ErrorDetails.Message
        if ($detail) {
            throw "xAI returned HTTP $status. $detail"
        }
        throw "xAI returned HTTP $status. Confirm the key, credits, model access and outbound access to api.x.ai."
    }
    throw "The xAI request failed. Confirm outbound access to api.x.ai and try again. Details: $($_.Exception.Message)"
}
finally {
    Remove-Variable apiKey, headers -ErrorAction SilentlyContinue
}

$returnedSignals = @()
foreach ($response in $responses) {
    $message = @($response.output | Where-Object { $_.type -eq "message" }) | Select-Object -Last 1
    $textBlock = @($message.content | Where-Object { $_.type -eq "output_text" }) | Select-Object -First 1
    if (-not $textBlock.text) {
        throw "xAI returned no structured feed text. No output file was changed."
    }

    try {
        $batchFeed = $textBlock.text | ConvertFrom-Json
        $returnedSignals += @($batchFeed.signals)
    }
    catch {
        throw "xAI returned text that was not valid feed JSON. No output file was changed."
    }
}
$feed = [pscustomobject]@{ signals = $returnedSignals }
$diagnosticDirectory = Join-Path $projectRoot "work"
New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
$diagnosticUtf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $diagnosticDirectory "x-candidates.json"), ($feed | ConvertTo-Json -Depth 20), $diagnosticUtf8)

function Get-IndependentUrls {
    param($Urls, [string]$OriginalUrl)
    try { $originalHost = ([uri]$OriginalUrl).Host.ToLowerInvariant() } catch { $originalHost = "" }
    $seenUrls = @{}
    $valid = @()
    foreach ($candidateUrl in @($Urls)) {
        try {
            $parsed = [uri]([string]$candidateUrl)
            if ($parsed.Scheme -ne "https" -or $parsed.Host.ToLowerInvariant() -eq $originalHost) { continue }
            $key = $parsed.AbsoluteUri.TrimEnd('/').ToLowerInvariant()
            if ($seenUrls.ContainsKey($key)) { continue }
            $seenUrls[$key] = $true
            $valid += $parsed.AbsoluteUri
            if ($valid.Count -ge 3) { break }
        } catch {}
    }
    return @($valid)
}

$validSignals = @()
$rejectedSignals = @()
foreach ($item in @($feed.signals)) {
    $rejectionReasons = @()
    if ($item.url -notmatch '^https://(www\.)?x\.com/[^/]+/status/\d+') {
        $rejectedSignals += [pscustomobject]@{ title = [string]$item.title; source = [string]$item.source; url = [string]$item.url; rejectionReasons = @("Invalid direct X post URL.") }
        continue
    }

    $item.significance = [Math]::Max(0, [Math]::Min(40, [int]$item.significance))
    $item.credibility = [Math]::Max(0, [Math]::Min(25, [int]$item.credibility))
    $item.timeliness = [Math]::Max(0, [Math]::Min(20, [int]$item.timeliness))
    $item.depth = [Math]::Max(0, [Math]::Min(15, [int]$item.depth))
    $item.entities = @($item.entities | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 8)
    $item.corroboratingUrls = @(Get-IndependentUrls $item.corroboratingUrls ([string]$item.url))
    $item.hasIndependentConfirmation = $item.corroboratingUrls.Count -gt 0

    $normalizedHandle = ([string]$item.handle).Trim().TrimStart('@').ToLowerInvariant()
    if (-not $tierByHandle.ContainsKey($normalizedHandle)) {
        try { $normalizedHandle = ([uri]$item.url).Segments[1].Trim('/').ToLowerInvariant() } catch {}
    }
    $sourceTier = if ($tierByHandle.ContainsKey($normalizedHandle)) { $tierByHandle[$normalizedHandle] } else { "unknown" }
    if ($item.PSObject.Properties["sourceTier"]) { $item.sourceTier = $sourceTier }
    else { $item | Add-Member -NotePropertyName sourceTier -NotePropertyValue $sourceTier }

    $cap = 100
    if ($item.postType -eq "rumor") { $cap = [Math]::Min($cap, 59) }
    if (-not $item.hasPrimaryEvidence -and -not $item.hasIndependentConfirmation) { $cap = [Math]::Min($cap, 69) }
    if ($item.postType -eq "commentary") { $cap = [Math]::Min($cap, 74) }
    if ($item.postType -eq "analysis" -and -not $item.hasPrimaryEvidence) { $cap = [Math]::Min($cap, 79) }
    if (-not ($item.hasPrimaryEvidence -and $item.hasIndependentConfirmation -and $item.hasMeasurableFirstOrderImpact)) {
        $cap = [Math]::Min($cap, 89)
    }

    $total = [int]$item.significance + [int]$item.credibility + [int]$item.timeliness + [int]$item.depth
    $excess = [Math]::Max(0, $total - $cap)
    foreach ($field in @("significance", "credibility", "depth", "timeliness")) {
        if ($excess -le 0) { break }
        $reduction = [Math]::Min([int]$item.$field, $excess)
        $item.$field = [int]$item.$field - $reduction
        $excess -= $reduction
    }
    $item.score = [int]$item.significance + [int]$item.credibility + [int]$item.timeliness + [int]$item.depth

    $passesTierPolicy = $item.score -ge 55
    if ($sourceTier -eq "context") {
        if ($item.postType -eq "commentary") {
            $passesTierPolicy = $item.score -ge 70
            if (-not $passesTierPolicy) { $rejectionReasons += "Context commentary requires a score of 70." }
        }
        else {
            $passesTierPolicy = $item.score -ge 60 -and ($item.hasPrimaryEvidence -or $item.hasIndependentConfirmation)
            if (-not $passesTierPolicy) { $rejectionReasons += "Context analysis requires a score of 60 plus primary evidence or independent confirmation." }
        }
    }
    if ($sourceTier -eq "event_gated") {
        $allowedEventType = $item.eventType -in @("model_release", "corporate", "research", "policy", "infrastructure", "supply_chain", "earnings")
        $allowedPostType = $item.postType -in @("announcement", "research")
        $passesTierPolicy = $item.score -ge 55 -and $item.hasPrimaryEvidence -and $allowedPostType -and $allowedEventType
        if (-not $passesTierPolicy) { $rejectionReasons += "Event-gated account did not provide a qualifying primary announcement or research item." }
    }
    if ($sourceTier -eq "unknown") { $passesTierPolicy = $false; $rejectionReasons += "Source was not in the configured account policy." }
    if ($item.eventType -eq "other" -and $item.score -lt 70) {
        $passesTierPolicy = $false
        $rejectionReasons += "Unclassified item requires a score of 70 to enter the AI-stack feed."
    }
    if ($item.score -lt 55 -and $rejectionReasons.Count -eq 0) { $rejectionReasons += "Below the 55-point curated-post threshold." }

    if ($passesTierPolicy) {
        $validSignals += $item
    }
    else {
        $rejectedSignals += [pscustomobject]@{
            eventKey = [string]$item.eventKey
            title = [string]$item.title
            source = [string]$item.source
            url = [string]$item.url
            score = [int]$item.score
            sourceTier = $sourceTier
            rejectionReasons = @($rejectionReasons | Select-Object -Unique)
        }
    }
}

[IO.File]::WriteAllText((Join-Path $diagnosticDirectory "x-rejections.json"), ($rejectedSignals | ConvertTo-Json -Depth 10), $diagnosticUtf8)

$finalSignals = @($validSignals |
    Group-Object { ([string]$_.url).Trim().ToLowerInvariant() } |
    ForEach-Object { $_.Group | Sort-Object score -Descending | Select-Object -First 1 } |
    Sort-Object score -Descending |
    Select-Object -First $MaxSignals)

$finalFeed = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    source = "xAI X Search"
    lookbackHours = $LookbackHours
    handles = $handles
    sourcePolicy = [ordered]@{ core = $coreHandles; context = $contextHandles; eventGated = $eventGatedHandles }
    signals = $finalSignals
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outputPath, ($finalFeed | ConvertTo-Json -Depth 20), $utf8)

$feedMerger = Join-Path $PSScriptRoot "merge-live-feeds.ps1"
& $feedMerger | Out-Host

Write-Host ""
Write-Host "Created a local feed with $($finalSignals.Count) verified-link X signals." -ForegroundColor Green
Write-Host "Open the live dashboard in outputs\signal-desk-live.html"
