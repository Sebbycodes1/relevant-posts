[CmdletBinding()]
param(
    [ValidateRange(1, 72)]
    [int]$PrimaryLookbackHours = 24,

    [ValidateRange(24, 168)]
    [int]$FallbackLookbackHours = 72,

    [ValidateRange(1, 20)]
    [int]$MaxEvents = 12,

    [ValidateRange(1, 8)]
    [int]$MinimumCandidatesPerLane = 5,

    [ValidateRange(1, 3)]
    [int]$MaxDiscoveryPasses = 2,

    [string]$Model = "grok-4.5",

    [switch]$ReplayCandidates
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot "outputs\live-breaking-feed.json"
$diagnosticDirectory = Join-Path $projectRoot "work"
$candidatesPath = Join-Path $diagnosticDirectory "breaking-candidates.json"
$historyPath = Join-Path $diagnosticDirectory "verified-event-history.json"
$publishedDashboardPath = Join-Path $projectRoot "docs\index.html"
. (Join-Path $PSScriptRoot "xai-key.ps1")

New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$previousSignals = @()

if (Test-Path -LiteralPath $historyPath) {
    try {
        $history = [IO.File]::ReadAllText($historyPath) | ConvertFrom-Json
        $previousSignals += @($history.signals)
    } catch {}
}
if (Test-Path -LiteralPath $publishedDashboardPath) {
    try {
        $publishedHtml = [IO.File]::ReadAllText($publishedDashboardPath)
        $signalMatch = [regex]::Match($publishedHtml, '(?s)const demoSignals = (\[.*?\]);\s*const ')
        if ($signalMatch.Success) {
            $publishedSignalData = $signalMatch.Groups[1].Value | ConvertFrom-Json
            $publishedSignals = @($publishedSignalData)
            foreach ($publishedSignal in @($publishedSignals | Where-Object { [bool]$_.mustInclude })) {
                if ($publishedSignal.primarySourceUrl) {
                    $publishedSignal.url = [string]$publishedSignal.primarySourceUrl
                    $publishedSignal.source = [string]$publishedSignal.primarySourceName
                    $publishedSignal.platform = [string]$publishedSignal.primarySourcePlatform
                    $publishedSignal.publishedAt = [string]$publishedSignal.eventPublishedAt
                }
                $previousSignals += $publishedSignal
            }
        }
    } catch {}
}

if (Test-Path -LiteralPath $outputPath) {
    try {
        $previousFeed = [IO.File]::ReadAllText($outputPath) | ConvertFrom-Json
        $previousSignals += @($previousFeed.signals)
    } catch {}
}

$now = Get-Date
$nowUtc = $now.ToUniversalTime()
$primaryCutoff = $nowUtc.AddHours(-$PrimaryLookbackHours)
$fallbackCutoff = $nowUtc.AddHours(-$FallbackLookbackHours)
$fromDate = $fallbackCutoff.ToString("yyyy-MM-dd")
$toDate = $nowUtc.ToString("yyyy-MM-dd")
$laneCandidateLimit = 8
$discoveryLanes = @(
    [pscustomobject]@{
        name = "Models and laboratories"
        focus = "Frontier and open-weight model launches, weights, model cards, important repository changes, benchmark-changing research and material laboratory disclosures. Explicitly inspect official lab pages, Hugging Face, GitHub and broad X discussion."
    },
    [pscustomobject]@{
        name = "Chips memory and hardware"
        focus = "AI accelerators, custom silicon, memory and HBM, foundry, advanced packaging, networking, server hardware, supply constraints, capacity commitments and material customer or financing disclosures."
    },
    [pscustomobject]@{
        name = "Datacenters energy and networking"
        focus = "Datacenter leases and construction, power procurement and generation, cooling, networking capacity, financing and measurable infrastructure commitments that change available AI compute."
    },
    [pscustomobject]@{
        name = "Hyperscalers and enterprise AI"
        focus = "Material hyperscaler, cloud and enterprise-AI launches, deployments, customer wins, earnings disclosures and economic data. Exclude routine partnerships and promotional product updates."
    },
    [pscustomobject]@{
        name = "Policy standards and open source"
        focus = "Government actions, regulation, export controls, standards, public letters, coalitions, open-source or open-weight policy and coordinated industry positions with direct competitive or access implications."
    },
    [pscustomobject]@{
        name = "Market-moving capital capacity and earnings"
        focus = "Same-day public-company filings, earnings, financings, investments, leases, customer commitments, capacity reservations and quantified deal terms across the AI stack. Prioritize developments likely to matter to public-equity analysts, including smaller suppliers and infrastructure companies that broad technology scans often miss."
    }
)

$prompt = @"
You are the breaking-events editor for an institutional asset-management AI intelligence feed.

Current time: $($nowUtc.ToString("o"))

Your job is high-recall event discovery for one defined AI-stack lane, not account monitoring. Search broadly across unrestricted X and the web. Do not limit discovery to familiar accounts, publishers or companies. Use X attention to find events, then verify every included event against a direct primary source.

Use this sequence:
1. Discover potentially material events first published after $($primaryCutoff.ToString("o")).
2. Verify each event against a direct primary source: an official newsroom or product page, research paper, model card or repository, filing, regulator/government page, or the original official X announcement.
3. If fewer than five verified major events qualify in that 24-hour window, supplement with the strongest verified events first published after $($fallbackCutoff.ToString("o")).
4. Cluster all posts and articles about the same underlying development into one event. Choose the primary source as the event URL and attach genuinely independent coverage as supporting URLs.

Search the assigned lane systematically. Use multiple keyword and semantic searches rather than stopping after the first plausible result. Check both official sources and broad X discussion, including unfamiliar accounts. Avoid duplicating an event merely because multiple posts discuss it.

A major event changes capabilities, access, economics, capacity, regulation or competitive position. Examples include a model or weights release, benchmark-changing research, a material financing or capacity commitment, a filing or earnings disclosure, a major policy action or coalition, or a measurable infrastructure/supply-chain change. Routine promotion, partnerships without substance, repeated commentary, personality drama, engagement bait, vague claims and recycled news are not major events.

Do not use discussion volume as a substitute for significance. Never invent a URL, date, signer, metric, absence, quotation or confirmation. A negative claim such as a company not signing a letter requires reliable independent evidence; otherwise omit that detail. Every included event must have a working direct HTTPS primary-source URL.

Score the EVENT, not a post or author's fame, conservatively:
- Significance, 0-40: measurable change to products, capabilities, economics, capacity, regulation or competitive positioning.
- Credibility, 0-25: primary evidence, specificity and independent corroboration.
- Timeliness, 0-20: value from receiving the event now.
- Analytical depth, 0-15: mechanisms, quantification and explanatory value available in the evidence.

The total must equal the four components. Scores above 85 should be rare. A model release or policy letter alone should not score 90+. Reserve 90+ for an independently confirmed development with exceptional, measurable first-order market or capacity consequences. A short official announcement can still be a must-include major event even when analytical depth is low. Verified major events must be marked mustInclude and returned even when their score is below 60. Rumors and events without primary verification must be excluded.

For auditability, return up to $laneCandidateLimit plausible candidate events for this lane, including excluded candidates. Set decision to include only for verified, genuinely material events. Give every excluded candidate a concise rejectionReason.

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
            maxItems = $laneCandidateLimit
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
    max_turns = 6
    text = [ordered]@{
        format = [ordered]@{
            type = "json_schema"
            name = "relevant_posts_breaking_events"
            schema = $schema
            strict = $true
        }
    }
    max_output_tokens = 7000
    store = $false
}

if ($ReplayCandidates) {
    if (-not (Test-Path -LiteralPath $candidatesPath)) { throw "No saved breaking-event candidates are available to replay." }
    $result = [IO.File]::ReadAllText($candidatesPath) | ConvertFrom-Json
    Write-Host "Replaying the saved breaking-event candidates through the local policy layer..." -ForegroundColor Cyan
}
else {
    $apiKey = Get-XaiApiKey -ProjectRoot $projectRoot
    $allCandidates = @()
    $laneAudit = @()
    try {
        for ($laneIndex = 0; $laneIndex -lt $discoveryLanes.Count; $laneIndex++) {
            $lane = $discoveryLanes[$laneIndex]
            $laneCandidates = @()
            $lanePasses = 0
            for ($pass = 1; $pass -le $MaxDiscoveryPasses; $pass++) {
                $lanePasses = $pass
                $alreadyFound = @($laneCandidates | ForEach-Object { "$($_.publishedAt) | $($_.title)" }) -join "`n"
                $retryContext = if ($alreadyFound) {
                    @"

This is pass $pass. The prior pass found the items below. Do not repeat them; search different query formulations, organizations and source types to fill gaps:
$alreadyFound
"@
                } else { "" }
                $requestBody.input = "$prompt`n`nAssigned discovery lane: $($lane.name)`nLane focus: $($lane.focus)$retryContext"
                Write-Host "Scanning breaking events - lane $($laneIndex + 1) of $($discoveryLanes.Count), pass $pass`: $($lane.name)..." -ForegroundColor Cyan
                $response = Invoke-RestMethod `
                    -Method Post `
                    -Uri "https://api.x.ai/v1/responses" `
                    -Headers @{ Authorization = "Bearer $apiKey" } `
                    -ContentType "application/json" `
                    -Body ($requestBody | ConvertTo-Json -Depth 30 -Compress) `
                    -TimeoutSec 420

                $message = @($response.output | Where-Object { $_.type -eq "message" }) | Select-Object -Last 1
                $textBlock = @($message.content | Where-Object { $_.type -eq "output_text" }) | Select-Object -First 1
                if (-not $textBlock.text) { throw "xAI returned no structured results for the $($lane.name) lane." }
                try {
                    $laneResult = $textBlock.text | ConvertFrom-Json
                }
                catch {
                    throw "xAI returned invalid event JSON for the $($lane.name) lane."
                }

                $laneCandidates += @($laneResult.candidates)
                $laneCandidates = @($laneCandidates |
                    Group-Object {
                        if ($_.primarySourceUrl) { ([string]$_.primarySourceUrl).TrimEnd('/').ToLowerInvariant() }
                        else { ([string]$_.eventKey).Trim().ToLowerInvariant() }
                    } |
                    ForEach-Object { $_.Group | Select-Object -First 1 })
                if ($laneCandidates.Count -ge $MinimumCandidatesPerLane) { break }
            }
            foreach ($candidate in $laneCandidates) {
                $candidate | Add-Member -NotePropertyName discoveryLane -NotePropertyValue $lane.name -Force
            }
            $allCandidates += $laneCandidates
            $laneAudit += [pscustomobject]@{
                lane = $lane.name
                candidateCount = $laneCandidates.Count
                passes = $lanePasses
            }
        }

        $candidateHeadlines = @($allCandidates | ForEach-Object {
            "$($_.publishedAt) | $($_.title) | $($_.primarySourceUrl)"
        } | Select-Object -First 60) -join "`n"
        $gapAuditName = "Cross-lane breaking gap audit"
        $requestBody.input = @"
$prompt

This is a final cross-lane gap audit, not another topical lane. The preceding scans found the candidate list below:
$candidateHeadlines

Search the current 24-hour window again across unrestricted X, official press releases, financial wires, filings, model repositories and lab newsrooms. Use broad X discussion as a gap-finding surface: search "announces", "released", "weights", "today", "earnings", "MW", "GW", "investment" and comparable semantic variants, then verify against primary sources. Return only material events missing from the supplied list. Pay particular attention to same-day model or weights releases, major lab investments, earnings disclosures, multi-hundred-megawatt or billion-dollar infrastructure commitments, semiconductor supply agreements and coordinated policy announcements. Do not repeat an event already represented above.
"@
        Write-Host "Scanning breaking events - final cross-lane gap audit..." -ForegroundColor Cyan
        $gapResponse = Invoke-RestMethod `
            -Method Post `
            -Uri "https://api.x.ai/v1/responses" `
            -Headers @{ Authorization = "Bearer $apiKey" } `
            -ContentType "application/json" `
            -Body ($requestBody | ConvertTo-Json -Depth 30 -Compress) `
            -TimeoutSec 420
        $gapMessage = @($gapResponse.output | Where-Object { $_.type -eq "message" }) | Select-Object -Last 1
        $gapTextBlock = @($gapMessage.content | Where-Object { $_.type -eq "output_text" }) | Select-Object -First 1
        if (-not $gapTextBlock.text) { throw "xAI returned no structured results for the cross-lane gap audit." }
        try {
            $gapResult = $gapTextBlock.text | ConvertFrom-Json
        }
        catch {
            throw "xAI returned invalid event JSON for the cross-lane gap audit."
        }
        $gapCandidates = @($gapResult.candidates)
        foreach ($candidate in $gapCandidates) {
            $candidate | Add-Member -NotePropertyName discoveryLane -NotePropertyValue $gapAuditName -Force
        }
        $allCandidates += $gapCandidates
        $laneAudit += [pscustomobject]@{
            lane = $gapAuditName
            candidateCount = $gapCandidates.Count
        }
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

    $result = [pscustomobject]@{
        generatedAt = $nowUtc.ToString("o")
        lanes = $laneAudit
        candidates = $allCandidates
    }
    [IO.File]::WriteAllText($candidatesPath, ($result | ConvertTo-Json -Depth 20), $utf8)
}

if (@($result.candidates).Count -eq 0) {
    throw "The broad event scan returned no candidates. The previous verified-event snapshot was retained and this lane was marked incomplete."
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

function Get-TitleTokens {
    param([string]$Title)
    $stopWords = @{
        "the"=$true; "and"=$true; "for"=$true; "with"=$true; "from"=$true; "that"=$true; "this"=$true;
        "into"=$true; "over"=$true; "after"=$true; "about"=$true; "new"=$true; "its"=$true; "are"=$true;
        "how"=$true; "what"=$true; "why"=$true; "announce"=$true; "announces"=$true; "ai"=$true
    }
    $normalized = [regex]::Replace(([string]$Title).ToLowerInvariant(), '[^a-z0-9]+', ' ')
    return @($normalized.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.Length -ge 3 -and -not $stopWords.ContainsKey($_) } |
        Select-Object -Unique)
}

function Get-TitleSimilarity {
    param([string]$Left, [string]$Right)
    $leftTokens = @(Get-TitleTokens $Left)
    $rightTokens = @(Get-TitleTokens $Right)
    if ($leftTokens.Count -lt 3 -or $rightTokens.Count -lt 3) { return 0 }
    $rightSet = @{}; foreach ($token in $rightTokens) { $rightSet[$token] = $true }
    $intersection = @($leftTokens | Where-Object { $rightSet.ContainsKey($_) }).Count
    $union = @($leftTokens + $rightTokens | Select-Object -Unique).Count
    if ($union -eq 0) { return 0 }
    return [double]$intersection / [double]$union
}

function Test-SameEvent {
    param($Left, $Right)
    $leftKey = ([string]$Left.eventKey).Trim().ToLowerInvariant()
    $rightKey = ([string]$Right.eventKey).Trim().ToLowerInvariant()
    if ($leftKey -and $rightKey -and $leftKey -eq $rightKey) { return $true }

    $leftUrl = ([string]$Left.url).TrimEnd('/').ToLowerInvariant()
    $rightUrl = ([string]$Right.url).TrimEnd('/').ToLowerInvariant()
    if ($leftUrl -and $rightUrl -and $leftUrl -eq $rightUrl) { return $true }

    try {
        $hoursApart = [Math]::Abs((([datetime]$Left.publishedAt) - ([datetime]$Right.publishedAt)).TotalHours)
        if ($hoursApart -gt 96) { return $false }
    } catch { return $false }

    $similarity = Get-TitleSimilarity ([string]$Left.title) ([string]$Right.title)
    if ($similarity -ge 0.50) { return $true }

    $leftEntities = @($Left.entities | ForEach-Object {
        [regex]::Replace(([string]$_).ToLowerInvariant(), '[^a-z0-9]+', '')
    } | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    $rightEntitySet = @{}
    foreach ($entity in @($Right.entities)) {
        $token = [regex]::Replace(([string]$entity).ToLowerInvariant(), '[^a-z0-9]+', '')
        if ($token.Length -ge 3) { $rightEntitySet[$token] = $true }
    }
    $entityOverlap = @($leftEntities | Where-Object { $rightEntitySet.ContainsKey($_) }).Count
    $sameType = $Left.eventType -and $Right.eventType -and
        ([string]$Left.eventType).ToLowerInvariant() -eq ([string]$Right.eventType).ToLowerInvariant()
    return $sameType -and $entityOverlap -gt 0 -and $similarity -ge 0.25
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
        discoveryLane = if ($item.PSObject.Properties["discoveryLane"]) { [string]$item.discoveryLane } else { "" }
        url = $primaryUrl
    }
}

$newAcceptedCount = $accepted.Count
if ($newAcceptedCount -eq 0) {
    throw "The broad event scan produced no newly verified events. The previous verified-event snapshot was retained and this lane was marked incomplete."
}

foreach ($previous in $previousSignals) {
    try {
        $previousPublishedUtc = ([datetime]$previous.publishedAt).ToUniversalTime()
        $previousAgeHours = ($nowUtc - $previousPublishedUtc).TotalHours
        $dateOnlyTimestamp = $previousPublishedUtc.TimeOfDay.TotalMinutes -eq 0
        $maximumAge = if ($dateOnlyTimestamp) { $FallbackLookbackHours + 24 } else { $FallbackLookbackHours + 8 }
        if ($previousAgeHours -ge -2 -and $previousAgeHours -le $maximumAge) {
            $previous.discoveryWindowHours = if ($previousAgeHours -le 24) { 24 } else { 72 }
            $previous.isBreaking = $previousAgeHours -ge 0 -and $previousAgeHours -le 24
            $accepted += $previous
        }
    } catch {}
}

$acceptedByQuality = @($accepted | Sort-Object `
    @{ Expression = { [int]$_.score }; Descending = $true }, `
    @{ Expression = { if ([bool]$_.isBreaking) { 1 } else { 0 } }; Descending = $true }, `
    @{ Expression = { try { ([datetime]$_.publishedAt).Ticks } catch { 0 } }; Descending = $true })

$deduplicatedAccepted = @()
foreach ($candidate in $acceptedByQuality) {
    $duplicate = $false
    foreach ($existing in $deduplicatedAccepted) {
        if (Test-SameEvent $candidate $existing) {
            $duplicate = $true
            break
        }
    }
    if (-not $duplicate) { $deduplicatedAccepted += $candidate }
}

$historyFeed = [ordered]@{
    generatedAt = $nowUtc.ToString("o")
    retentionHours = $FallbackLookbackHours + 24
    signals = $deduplicatedAccepted
}
[IO.File]::WriteAllText($historyPath, ($historyFeed | ConvertTo-Json -Depth 20), $utf8)

$accepted = @($deduplicatedAccepted |
    Sort-Object `
        @{ Expression = { [int]$_.score }; Descending = $true }, `
        @{ Expression = { if ([bool]$_.isBreaking) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { try { ([datetime]$_.publishedAt).Ticks } catch { 0 } }; Descending = $true } |
    Select-Object -First $MaxEvents)

[IO.File]::WriteAllText((Join-Path $diagnosticDirectory "breaking-rejections.json"), ($rejected | ConvertTo-Json -Depth 10), $utf8)

$feed = [ordered]@{
    generatedAt = $nowUtc.ToString("o")
    source = "Broad AI event discovery"
    primaryLookbackHours = $PrimaryLookbackHours
    fallbackLookbackHours = $FallbackLookbackHours
    discoveryLanes = @($result.lanes)
    signals = $accepted
}
[IO.File]::WriteAllText($outputPath, ($feed | ConvertTo-Json -Depth 20), $utf8)

$merger = Join-Path $PSScriptRoot "merge-live-feeds.ps1"
& $merger | Out-Host
Write-Host "Created a broad event feed with $($accepted.Count) verified major events; $($rejected.Count) candidates were excluded." -ForegroundColor Green
