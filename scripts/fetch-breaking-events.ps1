[CmdletBinding()]
param(
    [ValidateRange(1, 72)]
    [int]$PrimaryLookbackHours = 24,

    [ValidateRange(24, 168)]
    [int]$FallbackLookbackHours = 72,

    [ValidateRange(1, 20)]
    [int]$MaxEvents = 12,

    [string]$Model = "grok-4.5",

    [switch]$ReplayCandidates
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot "outputs\live-breaking-feed.json"
$diagnosticDirectory = Join-Path $projectRoot "work"
$candidatesPath = Join-Path $diagnosticDirectory "breaking-candidates.json"
. (Join-Path $PSScriptRoot "xai-key.ps1")

New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

$now = Get-Date
$nowUtc = $now.ToUniversalTime()
$primaryCutoff = $nowUtc.AddHours(-$PrimaryLookbackHours)
$fallbackCutoff = $nowUtc.AddHours(-$FallbackLookbackHours)
$fromDate = $fallbackCutoff.ToString("yyyy-MM-dd")
$toDate = $nowUtc.ToString("yyyy-MM-dd")
$candidateLimit = [Math]::Min(24, [Math]::Max(12, $MaxEvents * 2))

$prompt = @"
You are the breaking-events editor for an institutional asset-management AI intelligence feed.

Current time: $($nowUtc.ToString("o"))

Your job is event discovery, not account monitoring. Search broadly across unrestricted X and the web for material AI-stack developments. Do not limit discovery to familiar accounts, publishers or companies.

Use this sequence:
1. Discover potentially material events first published after $($primaryCutoff.ToString("o")).
2. Verify each event against a direct primary source: an official newsroom or product page, research paper, model card or repository, filing, regulator/government page, or the original official X announcement.
3. If fewer than five verified major events qualify in that 24-hour window, supplement with the strongest verified events first published after $($fallbackCutoff.ToString("o")).
4. Cluster all posts and articles about the same underlying development into one event. Choose the primary source as the event URL and attach genuinely independent coverage as supporting URLs.

Run distinct discovery lanes before ranking:
- Frontier and open-weight model launches, weights, model cards and important repository changes, including Hugging Face and GitHub.
- Policy actions, public letters, standards, coalitions and coordinated industry positions involving AI access, safety, regulation or open source.
- Compute, memory, semiconductor, networking, power and datacenter capacity or financing.
- Material laboratory, hyperscaler and enterprise-AI product or economic disclosures.

Before finalizing, explicitly check official AI-lab and hyperscaler newsrooms plus broad X discussion for a major model/weights release or AI-policy coalition that a generic news query may have missed. Use X attention to discover an event, never as its verification.

Search the entire AI stack: frontier and open-weight models, laboratories, memory, chips, semiconductors, hardware, energy, datacenters, hyperscalers, cloud, networking, software, policy, financing, supply chains and material customer deployments.

A major event changes capabilities, access, economics, capacity, regulation or competitive position. Examples include a model or weights release, benchmark-changing research, a material financing or capacity commitment, a filing or earnings disclosure, a major policy action or coalition, or a measurable infrastructure/supply-chain change. Routine promotion, partnerships without substance, repeated commentary, personality drama, engagement bait, vague claims and recycled news are not major events.

Do not use discussion volume as a substitute for significance. Never invent a URL, date, signer, metric, absence, quotation or confirmation. A negative claim such as a company not signing a letter requires reliable independent evidence; otherwise omit that detail. Every included event must have a working direct HTTPS primary-source URL.

Score the EVENT, not a post or author's fame, conservatively:
- Significance, 0-40: measurable change to products, capabilities, economics, capacity, regulation or competitive positioning.
- Credibility, 0-25: primary evidence, specificity and independent corroboration.
- Timeliness, 0-20: value from receiving the event now.
- Analytical depth, 0-15: mechanisms, quantification and explanatory value available in the evidence.

The total must equal the four components. Scores above 85 should be rare. A model release or policy letter alone should not score 90+. Reserve 90+ for an independently confirmed development with exceptional, measurable first-order market or capacity consequences. A short official announcement can still be a must-include major event even when analytical depth is low. Verified major events must be marked mustInclude and returned even when their score is below 60. Rumors and events without primary verification must be excluded.

For auditability, return up to $candidateLimit plausible candidate events, including excluded candidates. Set decision to include only for verified, genuinely material events. Give every excluded candidate a concise rejectionReason. Return no more than $MaxEvents included events.

Use neutral titles. Keep summaries factual and under 55 words. The implication should state the analyst question rather than an investment recommendation. Use one or more sectors from: Labs, Models, Memory, Chips, Semis, Hardware, Energy, Datacenters, Hyperscalers, Software, Policy, Networking, Cloud.
"@

$candidateProperties = [ordered]@{
    eventKey = @{ type = "string" }
    id = @{ type = "string" }
    source = @{ type = "string" }
    handle = @{ type = "string" }
    platform = @{ type = "string"; enum = @("X", "Web") }
    publishedAt = @{ type = "string" }
    title = @{ type = "string" }
    summary = @{ type = "string" }
    implication = @{ type = "string" }
    sectors = @{ type = "array"; items = @{ type = "string" }; minItems = 1; maxItems = 6 }
    significance = @{ type = "integer"; minimum = 0; maximum = 40 }
    credibility = @{ type = "integer"; minimum = 0; maximum = 25 }
    timeliness = @{ type = "integer"; minimum = 0; maximum = 20 }
    depth = @{ type = "integer"; minimum = 0; maximum = 15 }
    score = @{ type = "integer"; minimum = 0; maximum = 100 }
    postType = @{ type = "string"; enum = @("announcement", "research", "analysis", "commentary", "rumor") }
    eventType = @{ type = "string"; enum = @("model_release", "corporate", "research", "policy", "infrastructure", "supply_chain", "earnings", "commentary", "other") }
    entities = @{ type = "array"; items = @{ type = "string" }; maxItems = 8 }
    whyNow = @{ type = "string" }
    evidenceSummary = @{ type = "string" }
    primarySourceUrl = @{ type = "string" }
    supportingUrls = @{ type = "array"; items = @{ type = "string" }; maxItems = 4 }
    verificationStatus = @{ type = "string"; enum = @("primary", "primary_plus_independent", "unverified") }
    hasPrimaryEvidence = @{ type = "boolean" }
    hasIndependentConfirmation = @{ type = "boolean" }
    hasMeasurableFirstOrderImpact = @{ type = "boolean" }
    discoveryWindowHours = @{ type = "integer"; enum = @(24, 72) }
    isBreaking = @{ type = "boolean" }
    mustInclude = @{ type = "boolean" }
    decision = @{ type = "string"; enum = @("include", "exclude") }
    rejectionReason = @{ type = "string" }
}

$schema = [ordered]@{
    type = "object"
    properties = [ordered]@{
        generatedAt = @{ type = "string" }
        candidates = @{
            type = "array"
            maxItems = $candidateLimit
            items = [ordered]@{
                type = "object"
                properties = $candidateProperties
                required = @($candidateProperties.Keys)
                additionalProperties = $false
            }
        }
    }
    required = @("generatedAt", "candidates")
    additionalProperties = $false
}

$requestBody = [ordered]@{
    model = $Model
    input = $prompt
    tools = @(
        [ordered]@{
            type = "x_search"
            from_date = $fromDate
            to_date = $toDate
        },
        [ordered]@{ type = "web_search" }
    )
    text = [ordered]@{
        format = [ordered]@{
            type = "json_schema"
            name = "relevant_posts_breaking_events"
            schema = $schema
            strict = $true
        }
    }
    max_output_tokens = 16000
    store = $false
}

if ($ReplayCandidates) {
    if (-not (Test-Path -LiteralPath $candidatesPath)) { throw "No saved breaking-event candidates are available to replay." }
    $result = [IO.File]::ReadAllText($candidatesPath) | ConvertFrom-Json
    Write-Host "Replaying the saved breaking-event candidates through the local policy layer..." -ForegroundColor Cyan
}
else {
    $apiKey = Get-XaiApiKey -ProjectRoot $projectRoot
    try {
        Write-Host "Scanning broadly for breaking AI-stack events..." -ForegroundColor Cyan
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "https://api.x.ai/v1/responses" `
            -Headers @{ Authorization = "Bearer $apiKey" } `
            -ContentType "application/json" `
            -Body ($requestBody | ConvertTo-Json -Depth 30 -Compress) `
            -TimeoutSec 420
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__ 2>$null
        $detail = $_.ErrorDetails.Message
        if ($status -and $detail) { throw "xAI returned HTTP $status. $detail" }
        throw "Breaking-event discovery failed. $($_.Exception.Message)"
    }
    finally {
        Remove-Variable apiKey -ErrorAction SilentlyContinue
    }

    $message = @($response.output | Where-Object { $_.type -eq "message" }) | Select-Object -Last 1
    $textBlock = @($message.content | Where-Object { $_.type -eq "output_text" }) | Select-Object -First 1
    if (-not $textBlock.text) { throw "xAI returned no structured breaking-event results." }

    try {
        $result = $textBlock.text | ConvertFrom-Json
    }
    catch {
        throw "xAI returned invalid breaking-event JSON. No output file was changed."
    }
    [IO.File]::WriteAllText($candidatesPath, ($result | ConvertTo-Json -Depth 20), $utf8)
}

function Get-ValidHttpsUrls {
    param($Urls, [string]$PrimaryUrl)
    $seen = @{}
    $valid = @()
    foreach ($candidateUrl in @($Urls)) {
        try {
            $parsed = [uri]([string]$candidateUrl)
            if ($parsed.Scheme -ne "https") { continue }
            $key = $parsed.AbsoluteUri.TrimEnd('/').ToLowerInvariant()
            if ($key -eq $PrimaryUrl.TrimEnd('/').ToLowerInvariant() -or $seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $valid += $parsed.AbsoluteUri
            if ($valid.Count -ge 4) { break }
        } catch {}
    }
    return @($valid)
}

$accepted = @()
$rejected = @()
foreach ($item in @($result.candidates)) {
    $reasons = @()
    $primaryUrl = [string]$item.primarySourceUrl
    try {
        $primaryUri = [uri]$primaryUrl
        if ($primaryUri.Scheme -ne "https") { $reasons += "Primary URL is not HTTPS." }
    }
    catch {
        $reasons += "Primary URL is invalid."
    }

    $item.significance = [Math]::Max(0, [Math]::Min(40, [int]$item.significance))
    $item.credibility = [Math]::Max(0, [Math]::Min(25, [int]$item.credibility))
    $item.timeliness = [Math]::Max(0, [Math]::Min(20, [int]$item.timeliness))
    $item.depth = [Math]::Max(0, [Math]::Min(15, [int]$item.depth))
    $item.score = [int]$item.significance + [int]$item.credibility + [int]$item.timeliness + [int]$item.depth
    $item.entities = @($item.entities | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 8)
    $item.supportingUrls = @(Get-ValidHttpsUrls $item.supportingUrls $primaryUrl)
    $item.hasIndependentConfirmation = $item.supportingUrls.Count -gt 0 -and $item.verificationStatus -eq "primary_plus_independent"

    try {
        $publishedUtc = ([datetime]$item.publishedAt).ToUniversalTime()
        $ageHours = ($nowUtc - $publishedUtc).TotalHours
        $dateOnlyTimestamp = $publishedUtc.TimeOfDay.TotalMinutes -eq 0
        $maximumAge = if ($dateOnlyTimestamp) { $FallbackLookbackHours + 24 } else { $FallbackLookbackHours + 8 }
        if ($ageHours -lt -2 -or $ageHours -gt $maximumAge) { $reasons += "Published time is outside the discovery window." }
        $item.discoveryWindowHours = if ($publishedUtc -ge $primaryCutoff) { 24 } else { 72 }
        $item.isBreaking = $publishedUtc -ge $primaryCutoff
    }
    catch {
        $reasons += "Published time is invalid."
        $publishedUtc = $nowUtc
    }

    if ($item.decision -ne "include") { $reasons += $(if ($item.rejectionReason) { [string]$item.rejectionReason } else { "Discovery editor excluded the event." }) }
    if (-not $item.hasPrimaryEvidence -or $item.verificationStatus -eq "unverified") { $reasons += "No primary-source verification." }
    if (-not $item.mustInclude -and $item.score -lt 60) { $reasons += "Below the normal 60-point event threshold." }
    if ($item.postType -eq "rumor") { $reasons += "Rumor." }
    if ($item.eventType -eq "corporate" -and ([int]$item.significance -lt 30 -or -not $item.hasMeasurableFirstOrderImpact)) {
        $reasons += "Routine corporate or partnership announcement without measurable first-order impact."
    }

    $scoreCap = 89
    if ($item.eventType -in @("infrastructure", "supply_chain", "earnings") -and
        $item.hasPrimaryEvidence -and $item.hasIndependentConfirmation -and $item.hasMeasurableFirstOrderImpact) {
        $scoreCap = 94
    }
    $excess = [Math]::Max(0, [int]$item.score - $scoreCap)
    foreach ($field in @("depth", "timeliness", "significance", "credibility")) {
        if ($excess -le 0) { break }
        $reduction = [Math]::Min([int]$item.$field, $excess)
        $item.$field = [int]$item.$field - $reduction
        $excess -= $reduction
    }
    $item.score = [int]$item.significance + [int]$item.credibility + [int]$item.timeliness + [int]$item.depth

    if ($reasons.Count) {
        $rejected += [pscustomobject]@{
            eventKey = [string]$item.eventKey
            title = [string]$item.title
            source = [string]$item.source
            score = [int]$item.score
            primarySourceUrl = $primaryUrl
            rejectionReasons = @($reasons | Select-Object -Unique)
        }
        continue
    }

    $platform = if ($primaryUrl -match '^https://(www\.)?x\.com/') { "X" } else { "Web" }
    $ageHoursFloor = [Math]::Max(0, [Math]::Floor(($nowUtc - $publishedUtc).TotalHours))
    $age = if ($ageHoursFloor -lt 24) { "$([int]$ageHoursFloor)h" } else { "$([int][Math]::Floor($ageHoursFloor / 24))d" }
    $accepted += [pscustomobject][ordered]@{
        eventKey = [string]$item.eventKey
        id = if ($item.id) { [string]$item.id } else { "event-$([Math]::Abs(([string]$item.eventKey).GetHashCode()))" }
        source = [string]$item.source
        handle = [string]$item.handle
        platform = $platform
        age = $age
        publishedAt = $publishedUtc.ToString("o")
        score = [int]$item.score
        title = [string]$item.title
        summary = [string]$item.summary
        implication = [string]$item.implication
        sectors = @($item.sectors)
        significance = [int]$item.significance
        credibility = [int]$item.credibility
        timeliness = [int]$item.timeliness
        depth = [int]$item.depth
        postType = [string]$item.postType
        eventType = [string]$item.eventType
        entities = @($item.entities)
        whyNow = [string]$item.whyNow
        evidenceSummary = [string]$item.evidenceSummary
        corroboratingUrls = @($item.supportingUrls)
        hasPrimaryEvidence = [bool]$item.hasPrimaryEvidence
        hasIndependentConfirmation = [bool]$item.hasIndependentConfirmation
        hasMeasurableFirstOrderImpact = [bool]$item.hasMeasurableFirstOrderImpact
        discoveryWindowHours = [int]$item.discoveryWindowHours
        isBreaking = [bool]$item.isBreaking
        mustInclude = [bool]$item.mustInclude
        url = $primaryUrl
    }
}

$accepted = @($accepted |
    Group-Object { if ($_.eventKey) { $_.eventKey.ToLowerInvariant() } else { $_.url.ToLowerInvariant() } } |
    ForEach-Object { $_.Group | Sort-Object @{ Expression = "mustInclude"; Descending = $true }, score -Descending | Select-Object -First 1 } |
    Sort-Object @{ Expression = "mustInclude"; Descending = $true }, @{ Expression = "isBreaking"; Descending = $true }, @{ Expression = "score"; Descending = $true } |
    Select-Object -First $MaxEvents)

[IO.File]::WriteAllText((Join-Path $diagnosticDirectory "breaking-rejections.json"), ($rejected | ConvertTo-Json -Depth 10), $utf8)

$feed = [ordered]@{
    generatedAt = $nowUtc.ToString("o")
    source = "Broad AI event discovery"
    primaryLookbackHours = $PrimaryLookbackHours
    fallbackLookbackHours = $FallbackLookbackHours
    signals = $accepted
}
[IO.File]::WriteAllText($outputPath, ($feed | ConvertTo-Json -Depth 20), $utf8)

$merger = Join-Path $PSScriptRoot "merge-live-feeds.ps1"
& $merger | Out-Host
Write-Host "Created a broad event feed with $($accepted.Count) verified major events; $($rejected.Count) candidates were excluded." -ForegroundColor Green
