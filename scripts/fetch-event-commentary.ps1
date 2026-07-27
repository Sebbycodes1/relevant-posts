[CmdletBinding()]
param(
    [ValidateRange(55, 90)]
    [int]$MinimumCommentaryScore = 70,

    [ValidateRange(1, 14)]
    [int]$LookbackDays = 7,

    [ValidateRange(1, 6)]
    [int]$CandidatesPerEvent = 4,

    [string]$Model = "grok-4.5",

    [switch]$ReplayCandidates
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$eventFeedPath = Join-Path $projectRoot "outputs\live-breaking-feed.json"
$xFeedPath = Join-Path $projectRoot "outputs\live-x-feed.json"
$rssCandidatesPath = Join-Path $projectRoot "work\substack-candidates.json"
$outputPath = Join-Path $projectRoot "outputs\live-commentary-feed.json"
$diagnosticDirectory = Join-Path $projectRoot "work"
$candidateAuditPath = Join-Path $diagnosticDirectory "commentary-candidates.json"
$rejectionAuditPath = Join-Path $diagnosticDirectory "commentary-rejections.json"
. (Join-Path $PSScriptRoot "xai-key.ps1")

New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $eventFeedPath)) {
    throw "No verified event feed is available for commentary enrichment."
}

$eventFeed = [IO.File]::ReadAllText($eventFeedPath) | ConvertFrom-Json
$nowUtc = (Get-Date).ToUniversalTime()
$events = @($eventFeed.signals | Where-Object {
    try {
        ($nowUtc - ([datetime]$_.publishedAt).ToUniversalTime()).TotalDays -le $LookbackDays
    }
    catch { $false }
} | Select-Object eventKey, title, summary, entities, eventType, publishedAt, url)

if ($events.Count -eq 0) {
    $emptyFeed = [ordered]@{
        generatedAt = $nowUtc.ToString("o")
        source = "Targeted X and newsletter commentary"
        eventsExamined = 0
        minimumCommentaryScore = $MinimumCommentaryScore
        commentaries = @()
    }
    [IO.File]::WriteAllText($outputPath, ($emptyFeed | ConvertTo-Json -Depth 10), $utf8)
    & (Join-Path $PSScriptRoot "merge-live-feeds.ps1") | Out-Host
    return
}

$rssCandidates = @()
if (Test-Path -LiteralPath $rssCandidatesPath) {
    $rssCandidates = @([IO.File]::ReadAllText($rssCandidatesPath) | ConvertFrom-Json |
        Select-Object id, source, title, publishedAt, url, excerpt)
}

$preferredHandles = @()
if (Test-Path -LiteralPath $xFeedPath) {
    try {
        $xFeed = [IO.File]::ReadAllText($xFeedPath) | ConvertFrom-Json
        $preferredHandles = @($xFeed.handles | ForEach-Object { ([string]$_).Trim().TrimStart('@') } | Where-Object { $_ } | Select-Object -Unique)
    } catch {}
}

$earliestEvent = @($events | ForEach-Object {
    try { ([datetime]$_.publishedAt).ToUniversalTime() } catch {}
} | Where-Object { $_ } | Sort-Object | Select-Object -First 1)
$fromDate = if ($earliestEvent.Count) { $earliestEvent[0].ToString("yyyy-MM-dd") } else { $nowUtc.AddDays(-$LookbackDays).ToString("yyyy-MM-dd") }
$toDate = $nowUtc.ToString("yyyy-MM-dd")
$candidateLimit = [Math]::Min(30, $events.Count * $CandidatesPerEvent)
$eventsJson = $events | ConvertTo-Json -Depth 8 -Compress
$rssJson = $rssCandidates | ConvertTo-Json -Depth 6 -Compress

$prompt = @"
You are the commentary editor for an institutional asset-management AI intelligence feed.

Current time: $($nowUtc.ToString("o"))

The supplied events have already been verified against primary sources. Your job is to find the best X post or supplied newsletter/RSS article that adds meaningful interpretation to each event. Do not rediscover or rescore the event itself.

For every supplied event:
1. Search unrestricted X from the event date through today using the exact model/product name, entities, distinctive terms and primary URL.
2. Check the supplied RSS candidates for a clearly matching article.
3. Prefer the configured watchlist when quality is equal, but allow an unfamiliar author whose post is specific, evidence-led and genuinely useful.
4. Return at least three plausible candidates per event when available, including rejected borderline candidates for audit. It is acceptable to return no qualifying commentary for an event.

Timing is a hard rule. Commentary must be published at or after the supplied event publishedAt and must clearly respond to the completed release, publication or announcement. Exclude predictions, previews, leaks, anticipatory threads and posts that merely happen to discuss the same product before it was released. Even a correct prediction is not post-event commentary. When the event timestamp is date-only, use the post's language to determine whether it discusses the completed event rather than an anticipated one.

Preferred X watchlist:
$($preferredHandles -join ', ')

Commentary must add at least one of:
- new facts or measurements beyond the announcement;
- technical mechanism or benchmark interpretation;
- economic, competitive, policy, capacity or supply-chain analysis;
- a well-supported skeptical challenge to the primary claim;
- synthesis connecting the event to another independently sourced development.

Return English-language commentary only. Exclude announcement repetition, quote-posts without added analysis, generic praise, alarmism, unsupported predictions, engagement bait, personality commentary and generated-looking roundups. Reject sensational headlines, hidden-motive accusations and claims that a person or company is trying to ban or destroy something unless direct evidence supports the claim and the framing remains professional and neutral. Popularity and author fame are not quality signals. A post from the announcing company is not independent commentary unless it contains substantial new technical or economic analysis beyond the release.

Score COMMENTARY VALUE, not event significance:
- Incremental analytical insight, 0-35.
- Evidence and specificity, 0-25.
- Direct relevance to the event, 0-25.
- Independence from the primary announcement, 0-15.

The total must equal the components. Scores above 85 should be rare and no commentary should score above 89. Set decision to include only at $MinimumCommentaryScore or above, with at least 22 insight points, direct relevance, professional neutral tone and genuine independence. For an unfamiliar account, require both meaningful quantification and a direct evidence link in the post. Never invent a post, author, date, URL, claim or quotation.

For X, return a direct https://x.com/.../status/... URL found by X Search. For newsletters/RSS, return only an exact URL from the supplied candidates. Copy eventKey exactly from the supplied event. Keep the commentary summary factual and under 45 words.

Verified events:
$eventsJson

Untrusted newsletter/RSS candidates:
$rssJson
"@

$candidateProperties = [ordered]@{
    eventKey = @{ type = "string" }
    source = @{ type = "string" }
    handle = @{ type = "string" }
    platform = @{ type = "string"; enum = @("X", "Substack") }
    publishedAt = @{ type = "string" }
    url = @{ type = "string" }
    title = @{ type = "string" }
    summary = @{ type = "string" }
    incrementalValue = @{ type = "string" }
    analysisType = @{ type = "string"; enum = @("technical", "economic", "policy", "market", "skeptical", "synthesis", "repetition") }
    insight = @{ type = "integer"; minimum = 0; maximum = 35 }
    evidence = @{ type = "integer"; minimum = 0; maximum = 25 }
    relevance = @{ type = "integer"; minimum = 0; maximum = 25 }
    independence = @{ type = "integer"; minimum = 0; maximum = 15 }
    score = @{ type = "integer"; minimum = 0; maximum = 100 }
    addsNewFacts = @{ type = "boolean" }
    hasQuantification = @{ type = "boolean" }
    isIndependent = @{ type = "boolean" }
    hasDirectEvidenceLinks = @{ type = "boolean" }
    language = @{ type = "string"; enum = @("English", "Other") }
    tone = @{ type = "string"; enum = @("neutral", "advocacy", "alarmist", "unclear") }
    sourceFamiliarity = @{ type = "string"; enum = @("preferred", "established_new", "unknown") }
    temporalRelation = @{ type = "string"; enum = @("before_event", "after_event", "unclear") }
    respondsToCompletedEvent = @{ type = "boolean" }
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
        }
    )
    text = [ordered]@{
        format = [ordered]@{
            type = "json_schema"
            name = "relevant_posts_event_commentary"
            schema = $schema
            strict = $true
        }
    }
    max_output_tokens = 14000
    store = $false
}

if ($ReplayCandidates) {
    if (-not (Test-Path -LiteralPath $candidateAuditPath)) {
        throw "No saved commentary candidates are available to replay."
    }
    $result = [IO.File]::ReadAllText($candidateAuditPath) | ConvertFrom-Json
    Write-Host "Replaying saved commentary candidates through the local quality policy..." -ForegroundColor Cyan
}
else {
    $apiKey = Get-XaiApiKey -ProjectRoot $projectRoot
    try {
        Write-Host "Finding high-value commentary for verified events..." -ForegroundColor Cyan
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
        throw "Commentary enrichment failed. $($_.Exception.Message)"
    }
    finally {
        Remove-Variable apiKey -ErrorAction SilentlyContinue
    }

    $message = @($response.output | Where-Object { $_.type -eq "message" }) | Select-Object -Last 1
    $textBlock = @($message.content | Where-Object { $_.type -eq "output_text" }) | Select-Object -First 1
    if (-not $textBlock.text) { throw "xAI returned no structured commentary results." }
    try {
        $result = $textBlock.text | ConvertFrom-Json
    }
    catch {
        throw "xAI returned invalid commentary JSON. No output file was changed."
    }
    [IO.File]::WriteAllText($candidateAuditPath, ($result | ConvertTo-Json -Depth 20), $utf8)
}

function Get-CanonicalUrl {
    param([string]$Url)
    try {
        $builder = New-Object System.UriBuilder($Url)
        $builder.Query = ""
        $builder.Fragment = ""
        return $builder.Uri.AbsoluteUri.TrimEnd('/').ToLowerInvariant()
    }
    catch {
        return $Url.Trim().TrimEnd('/').ToLowerInvariant()
    }
}

$eventByKey = @{}
foreach ($event in $events) { $eventByKey[([string]$event.eventKey).ToLowerInvariant()] = $event }
$rssByUrl = @{}
foreach ($rss in $rssCandidates) { $rssByUrl[(Get-CanonicalUrl ([string]$rss.url))] = $rss }

$accepted = @()
$rejected = @()
foreach ($item in @($result.candidates)) {
    $reasons = @()
    $eventKey = ([string]$item.eventKey).Trim().ToLowerInvariant()
    if (-not $eventByKey.ContainsKey($eventKey)) { $reasons += "Event key does not match a verified event." }

    $item.insight = [Math]::Max(0, [Math]::Min(35, [int]$item.insight))
    $item.evidence = [Math]::Max(0, [Math]::Min(25, [int]$item.evidence))
    $item.relevance = [Math]::Max(0, [Math]::Min(25, [int]$item.relevance))
    $item.independence = [Math]::Max(0, [Math]::Min(15, [int]$item.independence))
    $item.score = [int]$item.insight + [int]$item.evidence + [int]$item.relevance + [int]$item.independence
    $excess = [Math]::Max(0, [int]$item.score - 89)
    foreach ($field in @("insight", "evidence", "relevance", "independence")) {
        if ($excess -le 0) { break }
        $reduction = [Math]::Min([int]$item.$field, $excess)
        $item.$field = [int]$item.$field - $reduction
        $excess -= $reduction
    }
    $item.score = [int]$item.insight + [int]$item.evidence + [int]$item.relevance + [int]$item.independence

    $canonicalUrl = Get-CanonicalUrl ([string]$item.url)
    if ($item.platform -eq "X") {
        if ($item.url -notmatch '^https://(www\.)?x\.com/[^/]+/status/\d+') { $reasons += "X result is not a direct post URL." }
    }
    elseif ($item.platform -eq "Substack") {
        if (-not $rssByUrl.ContainsKey($canonicalUrl)) { $reasons += "Newsletter URL was not in the collected RSS candidates." }
        else {
            $rssMatch = $rssByUrl[$canonicalUrl]
            $item.source = [string]$rssMatch.source
            $item.title = [string]$rssMatch.title
            $item.publishedAt = [string]$rssMatch.publishedAt
            $item.url = [string]$rssMatch.url
        }
    }

    $eventPublishedUtc = $null
    if ($eventByKey.ContainsKey($eventKey)) {
        $event = $eventByKey[$eventKey]
        if ((Get-CanonicalUrl ([string]$event.url)) -eq (Get-CanonicalUrl ([string]$item.url))) {
            $reasons += "Commentary URL is the primary source."
        }
        try { $eventPublishedUtc = ([datetime]$event.publishedAt).ToUniversalTime() } catch { $reasons += "Verified event publication time is invalid." }
    }

    try {
        $publishedUtc = ([datetime]$item.publishedAt).ToUniversalTime()
        $ageDays = ($nowUtc - $publishedUtc).TotalDays
        if ($ageDays -lt -0.1 -or $ageDays -gt ($LookbackDays + 1)) { $reasons += "Commentary is outside the allowed time window." }
        if ($eventPublishedUtc -and $publishedUtc -lt $eventPublishedUtc) { $reasons += "Commentary predates the verified event." }
    }
    catch {
        $reasons += "Commentary publication time is invalid."
    }

    if ($item.decision -ne "include") {
        $reasons += $(if ($item.rejectionReason) { [string]$item.rejectionReason } else { "Commentary editor excluded the item." })
    }
    if ($item.score -lt $MinimumCommentaryScore) { $reasons += "Below the $MinimumCommentaryScore-point commentary threshold." }
    if ([int]$item.insight -lt 22) { $reasons += "Insufficient incremental analytical insight." }
    if (-not $item.isIndependent -or [int]$item.independence -lt 8) { $reasons += "Insufficient independence from the announcement." }
    if ($item.analysisType -eq "repetition") { $reasons += "Repeats the announcement without useful added analysis." }
    if ($item.temporalRelation -ne "after_event" -or -not $item.respondsToCompletedEvent) {
        $reasons += "Post is a prediction, preview or temporally unclear rather than post-event commentary."
    }
    if ($item.language -ne "English" -or ([string]$item.title) -match '[^\x00-\x7F]') { $reasons += "Commentary is not presentation-ready English." }
    if ($item.tone -ne "neutral") { $reasons += "Commentary tone is advocacy, alarmist or unclear rather than neutral." }
    if (([string]$item.title) -match '(?i)\b(entire category|everyone|no one|destroy|catastroph|doom|panic|insane|scam|fraud)\b|tried to get .{0,40}\bbanned\b') {
        $reasons += "Sensational or motive-attributing headline."
    }
    if ($item.sourceFamiliarity -eq "unknown" -and (-not $item.hasDirectEvidenceLinks -or -not $item.hasQuantification)) {
        $reasons += "Unfamiliar source must provide both meaningful quantification and a direct evidence link."
    }

    if ($reasons.Count) {
        $rejected += [pscustomobject]@{
            eventKey = [string]$item.eventKey
            source = [string]$item.source
            title = [string]$item.title
            url = [string]$item.url
            score = [int]$item.score
            rejectionReasons = @($reasons | Select-Object -Unique)
        }
        continue
    }

    $accepted += [pscustomobject][ordered]@{
        eventKey = [string]$item.eventKey
        source = [string]$item.source
        handle = [string]$item.handle
        platform = [string]$item.platform
        publishedAt = $publishedUtc.ToString("o")
        url = [string]$item.url
        title = [string]$item.title
        summary = [string]$item.summary
        incrementalValue = [string]$item.incrementalValue
        analysisType = [string]$item.analysisType
        commentaryScore = [int]$item.score
        insight = [int]$item.insight
        evidence = [int]$item.evidence
        relevance = [int]$item.relevance
        independence = [int]$item.independence
        addsNewFacts = [bool]$item.addsNewFacts
        hasQuantification = [bool]$item.hasQuantification
        isIndependent = [bool]$item.isIndependent
        hasDirectEvidenceLinks = [bool]$item.hasDirectEvidenceLinks
        language = [string]$item.language
        tone = [string]$item.tone
        sourceFamiliarity = [string]$item.sourceFamiliarity
        temporalRelation = [string]$item.temporalRelation
        respondsToCompletedEvent = [bool]$item.respondsToCompletedEvent
    }
}

$selected = @($accepted |
    Group-Object { ([string]$_.eventKey).ToLowerInvariant() } |
    ForEach-Object {
        $_.Group | Sort-Object `
            @{ Expression = { try { ([datetime]$_.publishedAt).Ticks } catch { 0 } }; Descending = $true }, `
            @{ Expression = { [int]$_.commentaryScore }; Descending = $true }, `
            @{ Expression = { [int]$_.insight }; Descending = $true } |
            Select-Object -First 1
    } |
    Sort-Object @{ Expression = { [int]$_.commentaryScore }; Descending = $true })

[IO.File]::WriteAllText($rejectionAuditPath, ($rejected | ConvertTo-Json -Depth 10), $utf8)

$feed = [ordered]@{
    generatedAt = $nowUtc.ToString("o")
    source = "Targeted X and newsletter commentary"
    eventsExamined = $events.Count
    minimumCommentaryScore = $MinimumCommentaryScore
    preferredHandles = $preferredHandles
    commentaries = $selected
}
[IO.File]::WriteAllText($outputPath, ($feed | ConvertTo-Json -Depth 20), $utf8)

& (Join-Path $PSScriptRoot "merge-live-feeds.ps1") | Out-Host
Write-Host "Selected commentary for $($selected.Count) of $($events.Count) verified events; $($rejected.Count) candidates were excluded." -ForegroundColor Green
