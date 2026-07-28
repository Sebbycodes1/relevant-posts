[CmdletBinding()]
param(
    [ValidateRange(55, 85)]
    [int]$MinimumCommentaryScore = 70,

    [ValidateRange(1, 14)]
    [int]$LookbackDays = 7,

    [ValidateRange(5, 15)]
    [int]$CandidatesPerEvent = 10,

    [ValidateRange(3, 10)]
    [int]$MinimumCandidatesPerEvent = 5,

    [ValidateRange(1, 2)]
    [int]$MaxDiscoveryPasses = 2,

    [string]$Model = "grok-4.5",

    [switch]$ReplayCandidates
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$eventFeedPath = Join-Path $projectRoot "outputs\live-breaking-feed.json"
$xFeedPath = Join-Path $projectRoot "outputs\live-x-feed.json"
$outputPath = Join-Path $projectRoot "outputs\live-commentary-feed.json"
$diagnosticDirectory = Join-Path $projectRoot "work"
$candidateAuditPath = Join-Path $diagnosticDirectory "commentary-candidates.json"
$gradingAuditPath = Join-Path $diagnosticDirectory "commentary-grades.json"
$rejectionAuditPath = Join-Path $diagnosticDirectory "commentary-rejections.json"
$coverageAuditPath = Join-Path $diagnosticDirectory "x-commentary-coverage.json"
$sourcePerformancePath = Join-Path $diagnosticDirectory "x-source-performance.json"
. (Join-Path $PSScriptRoot "xai-key.ps1")

New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$nowUtc = (Get-Date).ToUniversalTime()

if (-not (Test-Path -LiteralPath $eventFeedPath)) {
    throw "No verified event feed is available for commentary enrichment."
}

$eventFeed = [IO.File]::ReadAllText($eventFeedPath) | ConvertFrom-Json
$events = @($eventFeed.signals | Where-Object {
    try {
        ($nowUtc - ([datetime]$_.publishedAt).ToUniversalTime()).TotalDays -le $LookbackDays
    }
    catch { $false }
} | Select-Object eventKey, title, summary, entities, eventType, publishedAt, url, source, evidenceSummary)

if ($events.Count -eq 0) {
    $emptyFeed = [ordered]@{
        generatedAt = $nowUtc.ToString("o")
        source = "High-recall X commentary"
        eventsExamined = 0
        minimumCommentaryScore = $MinimumCommentaryScore
        commentaries = @()
    }
    [IO.File]::WriteAllText($outputPath, ($emptyFeed | ConvertTo-Json -Depth 10), $utf8)
    & (Join-Path $PSScriptRoot "merge-live-feeds.ps1") | Out-Host
    return
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
        return ([string]$Url).Trim().TrimEnd('/').ToLowerInvariant()
    }
}

function Get-ResponseJson {
    param($Response, [string]$Context)
    $message = @($Response.output | Where-Object { $_.type -eq "message" }) | Select-Object -Last 1
    $textBlock = @($message.content | Where-Object { $_.type -eq "output_text" }) | Select-Object -First 1
    if (-not $textBlock.text) { throw "xAI returned no structured results for $Context." }
    try {
        return $textBlock.text | ConvertFrom-Json
    }
    catch {
        throw "xAI returned invalid structured JSON for $Context."
    }
}

function Invoke-XaiStructuredRequest {
    param(
        [string]$ApiKey,
        $RequestBody,
        [string]$Context
    )
    try {
        $safeInput = [string]$RequestBody.input
        $safeInput = [regex]::Replace($safeInput, '(?i)\\ud[89ab][0-9a-f]{2}\\ud[c-f][0-9a-f]{2}', '')
        $safeInput = [regex]::Replace($safeInput, '(?i)\\ud[89ab][0-9a-f]{2}|\\ud[c-f][0-9a-f]{2}', '')
        $safeInput = [regex]::Replace($safeInput, '[^\u0009\u000a\u000d\u0020-\u007e]', ' ')
        $RequestBody.input = $safeInput
        $bodyJson = $RequestBody | ConvertTo-Json -Depth 35 -Compress
        $bodyJson = [Text.Encoding]::UTF8.GetString([Text.Encoding]::UTF8.GetBytes($bodyJson))
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "https://api.x.ai/v1/responses" `
            -Headers @{ Authorization = "Bearer $ApiKey" } `
            -ContentType "application/json" `
            -Body $bodyJson `
            -TimeoutSec 420
        return Get-ResponseJson $response $Context
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__ 2>$null
        $detail = $_.ErrorDetails.Message
        if ($status -and $detail) { throw "xAI returned HTTP $status while processing $Context. $detail" }
        throw "xAI request failed while processing $Context. $($_.Exception.Message)"
    }
}

$preferredHandles = @()
if (Test-Path -LiteralPath $xFeedPath) {
    try {
        $xFeed = [IO.File]::ReadAllText($xFeedPath) | ConvertFrom-Json
        $preferredHandles += @($xFeed.handles)
    } catch {}
}

$sourcePerformance = @()
if (Test-Path -LiteralPath $sourcePerformancePath) {
    try {
        $sourcePerformanceData = [IO.File]::ReadAllText($sourcePerformancePath) | ConvertFrom-Json
        $sourcePerformance = @($sourcePerformanceData)
        $preferredHandles += @($sourcePerformance | Where-Object {
            [int]$_.acceptedCount -ge 2 -and [double]$_.averageScore -ge 72
        } | ForEach-Object { $_.handle })
    } catch {}
}
$preferredHandles = @($preferredHandles | ForEach-Object {
    ([string]$_).Trim().TrimStart('@')
} | Where-Object { $_ } | Select-Object -Unique)
$preferredHandleSet = @{}
foreach ($handle in $preferredHandles) { $preferredHandleSet[$handle.ToLowerInvariant()] = $true }

$candidateProperties = [ordered]@{
    eventKey = @{ type = "string" }
    source = @{ type = "string" }
    handle = @{ type = "string" }
    publishedAt = @{ type = "string" }
    url = @{ type = "string" }
    title = @{ type = "string" }
    postText = @{ type = "string" }
    threadContext = @{ type = "string" }
    evidenceUrls = @{ type = "array"; items = @{ type = "string" }; maxItems = 4 }
    hasImageEvidence = @{ type = "boolean" }
    searchMatch = @{ type = "string" }
}
$candidateSchema = [ordered]@{
    type = "object"
    properties = [ordered]@{
        candidates = @{
            type = "array"
            maxItems = $CandidatesPerEvent
            items = [ordered]@{
                type = "object"
                properties = $candidateProperties
                required = @($candidateProperties.Keys)
                additionalProperties = $false
            }
        }
    }
    required = @("candidates")
    additionalProperties = $false
}

$gradeProperties = [ordered]@{
    url = @{ type = "string" }
    summary = @{ type = "string" }
    incrementalValue = @{ type = "string" }
    analysisType = @{ type = "string"; enum = @("technical", "economic", "policy", "market", "skeptical", "synthesis", "repetition") }
    analyticalValue = @{ type = "string"; enum = @("none", "low", "medium", "high", "exceptional") }
    evidenceQuality = @{ type = "string"; enum = @("none", "limited", "specific", "strong") }
    directRelevance = @{ type = "string"; enum = @("direct", "partial", "weak") }
    independenceQuality = @{ type = "string"; enum = @("none", "partial", "strong") }
    tone = @{ type = "string"; enum = @("neutral", "advocacy", "alarmist", "unclear") }
    sourceFamiliarity = @{ type = "string"; enum = @("preferred", "established_new", "unknown") }
    addsNewFacts = @{ type = "boolean" }
    hasQuantification = @{ type = "boolean" }
    hasDirectEvidenceLinks = @{ type = "boolean" }
    isRepetition = @{ type = "boolean" }
    appearsGenerated = @{ type = "boolean" }
    respondsToCompletedEvent = @{ type = "boolean" }
    language = @{ type = "string"; enum = @("English", "Other") }
}
$gradeSchema = [ordered]@{
    type = "object"
    properties = [ordered]@{
        grades = @{
            type = "array"
            maxItems = ($CandidatesPerEvent * $MaxDiscoveryPasses)
            items = [ordered]@{
                type = "object"
                properties = $gradeProperties
                required = @($gradeProperties.Keys)
                additionalProperties = $false
            }
        }
    }
    required = @("grades")
    additionalProperties = $false
}

$candidateEvents = @()
$gradingEvents = @()
$apiKey = $null

try {
    if ($ReplayCandidates) {
        if (-not (Test-Path -LiteralPath $candidateAuditPath) -or -not (Test-Path -LiteralPath $gradingAuditPath)) {
            throw "Saved commentary candidates and grades are required for replay."
        }
        $candidateAudit = [IO.File]::ReadAllText($candidateAuditPath) | ConvertFrom-Json
        $gradingAudit = [IO.File]::ReadAllText($gradingAuditPath) | ConvertFrom-Json
        $candidateEvents = @($candidateAudit.events)
        $gradingEvents = @($gradingAudit.events)
        Write-Host "Replaying saved X candidates through deterministic scoring..." -ForegroundColor Cyan
    }
    else {
        $apiKey = Get-XaiApiKey -ProjectRoot $projectRoot
        $checkpointCandidatesByKey = @{}
        $checkpointGradesByKey = @{}
        if ((Test-Path -LiteralPath $candidateAuditPath) -and (Test-Path -LiteralPath $gradingAuditPath)) {
            try {
                $savedCandidateAudit = [IO.File]::ReadAllText($candidateAuditPath) | ConvertFrom-Json
                $savedGradingAudit = [IO.File]::ReadAllText($gradingAuditPath) | ConvertFrom-Json
                $checkpointAgeHours = ($nowUtc - ([datetime]$savedCandidateAudit.generatedAt).ToUniversalTime()).TotalHours
                if ([int]$savedCandidateAudit.pipelineVersion -eq 2 -and [int]$savedGradingAudit.pipelineVersion -eq 2 -and $checkpointAgeHours -le 4) {
                    foreach ($savedEvent in @($savedCandidateAudit.events)) { $checkpointCandidatesByKey[([string]$savedEvent.eventKey).ToLowerInvariant()] = $savedEvent }
                    foreach ($savedEvent in @($savedGradingAudit.events)) { $checkpointGradesByKey[([string]$savedEvent.eventKey).ToLowerInvariant()] = $savedEvent }
                }
            } catch {}
        }

        for ($eventIndex = 0; $eventIndex -lt $events.Count; $eventIndex++) {
            $event = $events[$eventIndex]
            $eventKeyLower = ([string]$event.eventKey).ToLowerInvariant()
            if ($checkpointCandidatesByKey.ContainsKey($eventKeyLower) -and $checkpointGradesByKey.ContainsKey($eventKeyLower)) {
                Write-Host "Reusing completed X-search checkpoint - event $($eventIndex + 1) of $($events.Count)..." -ForegroundColor DarkCyan
                $candidateEvents += $checkpointCandidatesByKey[$eventKeyLower]
                $gradingEvents += $checkpointGradesByKey[$eventKeyLower]
                continue
            }
            $eventPublishedUtc = ([datetime]$event.publishedAt).ToUniversalTime()
            $fromDate = $eventPublishedUtc.ToString("yyyy-MM-dd")
            $toDate = $nowUtc.ToString("yyyy-MM-dd")
            $eventJson = $event | ConvertTo-Json -Depth 8 -Compress
            $eventCandidates = @()
            $passesRun = 0

            for ($pass = 1; $pass -le $MaxDiscoveryPasses; $pass++) {
                if ($pass -gt 1 -and $eventCandidates.Count -ge $MinimumCandidatesPerEvent) { break }
                $passesRun = $pass
                $existingUrls = @($eventCandidates | ForEach-Object { $_.url } | Select-Object -Unique)
                $retryInstruction = if ($pass -eq 1) {
                    "This is the primary discovery pass."
                }
                else {
                    "The first pass found too few usable candidates. Broaden the search to aliases, abbreviations, quote posts, technical specialists, finance and infrastructure analysts, replies that contain substantive analysis, and unfamiliar authors. Exclude these URLs already found: $($existingUrls -join ', ')"
                }

                $discoveryPrompt = @"
You are running high-recall X discovery for one verified AI-stack event in an institutional investor feed.

Current time: $($nowUtc.ToString("o"))
Verified event: $eventJson

$retryInstruction

Search X systematically from the event publication date through today. Perform distinct searches for:
1. The exact event or product name and announcing entities.
2. The primary-source URL, important metrics, technical terms and common abbreviations.
3. Semantic discussion of the event's technical, economic, competitive, capacity, policy or supply-chain implications.
4. Quote posts and threads responding to the completed announcement.

Collect up to $CandidatesPerEvent real posts. Maximize recall at this stage: include substantive candidates even when they may later fail the quality screen. Do not grade or rank them. Do not return predictions, previews or posts that predate the completed event. Use image understanding when a post contains a chart, table or screenshot with relevant evidence. Return only direct https://x.com/.../status/... URLs found by X Search. Never invent a URL, author, timestamp, quotation or linked source. Copy the supplied eventKey exactly.
"@
                $discoveryBody = [ordered]@{
                    model = $Model
                    input = $discoveryPrompt
                    tools = @(
                        [ordered]@{
                            type = "x_search"
                            from_date = $fromDate
                            to_date = $toDate
                            enable_image_understanding = $true
                        }
                    )
                    max_turns = 8
                    text = [ordered]@{
                        format = [ordered]@{
                            type = "json_schema"
                            name = "relevant_posts_x_candidate_discovery"
                            schema = $candidateSchema
                            strict = $true
                        }
                    }
                    max_output_tokens = 8500
                    store = $false
                }

                Write-Host "Finding X commentary - event $($eventIndex + 1) of $($events.Count), pass $pass..." -ForegroundColor Cyan
                $discoveryResult = Invoke-XaiStructuredRequest $apiKey $discoveryBody "X discovery for $($event.title)"
                foreach ($candidate in @($discoveryResult.candidates)) {
                    $candidate.eventKey = [string]$event.eventKey
                    if ($candidate.url -notmatch '^https://(www\.)?x\.com/[^/]+/status/\d+') { continue }
                    try {
                        $candidatePublishedUtc = ([datetime]$candidate.publishedAt).ToUniversalTime()
                        if ($candidatePublishedUtc -lt $eventPublishedUtc -or $candidatePublishedUtc -gt $nowUtc.AddMinutes(10)) { continue }
                        $candidate.publishedAt = $candidatePublishedUtc.ToString("o")
                    }
                    catch { continue }
                    $canonical = Get-CanonicalUrl ([string]$candidate.url)
                    if (@($eventCandidates | Where-Object { (Get-CanonicalUrl ([string]$_.url)) -eq $canonical }).Count -eq 0) {
                        if (-not $candidate.source -or $candidate.source -eq "X") { $candidate.source = [string]$candidate.handle }
                        $eventCandidates += $candidate
                    }
                }
            }

            $candidateEvents += [pscustomobject]@{
                eventKey = [string]$event.eventKey
                eventTitle = [string]$event.title
                passesRun = $passesRun
                candidates = @($eventCandidates)
            }

            if ($eventCandidates.Count -eq 0) {
                $gradingEvents += [pscustomobject]@{
                    eventKey = [string]$event.eventKey
                    grades = @()
                }
                $candidateCheckpoint = [ordered]@{ pipelineVersion = 2; generatedAt = $nowUtc.ToString("o"); targetCandidatesPerEvent = $CandidatesPerEvent; minimumCandidatesPerEvent = $MinimumCandidatesPerEvent; events = $candidateEvents }
                $gradingCheckpoint = [ordered]@{ pipelineVersion = 2; generatedAt = $nowUtc.ToString("o"); events = $gradingEvents }
                [IO.File]::WriteAllText($candidateAuditPath, ($candidateCheckpoint | ConvertTo-Json -Depth 20), $utf8)
                [IO.File]::WriteAllText($gradingAuditPath, ($gradingCheckpoint | ConvertTo-Json -Depth 20), $utf8)
                continue
            }

            $candidatesJson = $eventCandidates | ConvertTo-Json -Depth 10 -Compress
            $candidatesJson = [Text.Encoding]::UTF8.GetString([Text.Encoding]::UTF8.GetBytes($candidatesJson))
            $gradingPrompt = @"
You are the evidence editor for an institutional investor feed. Grade supplied X candidates for commentary value on one verified event. Do not search for new posts and do not assign numerical scores.

Current time: $($nowUtc.ToString("o"))
Verified event: $eventJson
Preferred handles: $($preferredHandles -join ', ')
Candidates: $candidatesJson

For every candidate URL, label only what the supplied post and thread context support. Commentary must respond to the completed event, be directly relevant, professional and add analysis beyond announcement repetition. Treat popularity and author fame as weak evidence. A useful unfamiliar author is allowed; unfamiliarity lowers source confidence but is not a rejection rule. Mark generated-looking roundups, sensational framing and unsupported claims honestly. Use established_new only for a recognizable specialist, company, journalist or analyst with a relevant track record. Keep summary under 45 words and incrementalValue to one sentence. Return one grade for every supplied URL and never invent content.
"@
            $gradingBody = [ordered]@{
                model = $Model
                input = $gradingPrompt
                text = [ordered]@{
                    format = [ordered]@{
                        type = "json_schema"
                        name = "relevant_posts_x_candidate_grading"
                        schema = $gradeSchema
                        strict = $true
                    }
                }
                max_output_tokens = 8500
                store = $false
            }
            $gradingResult = Invoke-XaiStructuredRequest $apiKey $gradingBody "commentary grading for $($event.title)"
            $gradingEvents += [pscustomobject]@{
                eventKey = [string]$event.eventKey
                grades = @($gradingResult.grades)
            }
            $candidateCheckpoint = [ordered]@{ pipelineVersion = 2; generatedAt = $nowUtc.ToString("o"); targetCandidatesPerEvent = $CandidatesPerEvent; minimumCandidatesPerEvent = $MinimumCandidatesPerEvent; events = $candidateEvents }
            $gradingCheckpoint = [ordered]@{ pipelineVersion = 2; generatedAt = $nowUtc.ToString("o"); events = $gradingEvents }
            [IO.File]::WriteAllText($candidateAuditPath, ($candidateCheckpoint | ConvertTo-Json -Depth 20), $utf8)
            [IO.File]::WriteAllText($gradingAuditPath, ($gradingCheckpoint | ConvertTo-Json -Depth 20), $utf8)
        }

        $candidateAudit = [ordered]@{
            pipelineVersion = 2
            generatedAt = $nowUtc.ToString("o")
            targetCandidatesPerEvent = $CandidatesPerEvent
            minimumCandidatesPerEvent = $MinimumCandidatesPerEvent
            events = $candidateEvents
        }
        $gradingAudit = [ordered]@{
            pipelineVersion = 2
            generatedAt = $nowUtc.ToString("o")
            events = $gradingEvents
        }
        [IO.File]::WriteAllText($candidateAuditPath, ($candidateAudit | ConvertTo-Json -Depth 20), $utf8)
        [IO.File]::WriteAllText($gradingAuditPath, ($gradingAudit | ConvertTo-Json -Depth 20), $utf8)
    }
}
finally {
    Remove-Variable apiKey -ErrorAction SilentlyContinue
}

$analysisPoints = @{ none = 0; low = 15; medium = 25; high = 33; exceptional = 38 }
$evidencePoints = @{ none = 2; limited = 9; specific = 17; strong = 22 }
$sourcePoints = @{ preferred = 15; established_new = 11; unknown = 7 }
$independencePoints = @{ none = 0; partial = 6; strong = 10 }

$eventByKey = @{}
foreach ($event in $events) { $eventByKey[([string]$event.eventKey).ToLowerInvariant()] = $event }
$gradesByEvent = @{}
foreach ($gradingEvent in $gradingEvents) {
    $gradesByEvent[([string]$gradingEvent.eventKey).ToLowerInvariant()] = @($gradingEvent.grades)
}

$accepted = @()
$rejected = @()
$coverage = @()
foreach ($candidateEvent in $candidateEvents) {
    $eventKey = ([string]$candidateEvent.eventKey).ToLowerInvariant()
    if (-not $eventByKey.ContainsKey($eventKey)) { continue }
    $event = $eventByKey[$eventKey]
    $eventPublishedUtc = ([datetime]$event.publishedAt).ToUniversalTime()
    $candidates = @($candidateEvent.candidates)
    $candidateByUrl = @{}
    foreach ($candidate in $candidates) {
        $candidateByUrl[(Get-CanonicalUrl ([string]$candidate.url))] = $candidate
    }

    $grades = if ($gradesByEvent.ContainsKey($eventKey)) { @($gradesByEvent[$eventKey]) } else { @() }
    foreach ($grade in $grades) {
        $canonicalUrl = Get-CanonicalUrl ([string]$grade.url)
        if (-not $candidateByUrl.ContainsKey($canonicalUrl)) { continue }
        $candidate = $candidateByUrl[$canonicalUrl]
        $reasons = @()
        $handle = ([string]$candidate.handle).Trim().TrimStart('@')
        $familiarity = ([string]$grade.sourceFamiliarity).ToLowerInvariant()
        if ($preferredHandleSet.ContainsKey($handle.ToLowerInvariant())) { $familiarity = "preferred" }
        if (-not $sourcePoints.ContainsKey($familiarity)) { $familiarity = "unknown" }

        try {
            $publishedUtc = ([datetime]$candidate.publishedAt).ToUniversalTime()
            if ($publishedUtc -lt $eventPublishedUtc) { $reasons += "Commentary predates the verified event." }
            $ageHours = ($nowUtc - $publishedUtc).TotalHours
        }
        catch {
            $publishedUtc = $nowUtc
            $ageHours = 999
            $reasons += "Commentary publication time is invalid."
        }

        $recencyScore = if ($ageHours -le 6) { 10 } elseif ($ageHours -le 12) { 9 } elseif ($ageHours -le 24) { 8 } elseif ($ageHours -le 48) { 6 } elseif ($ageHours -le 72) { 4 } else { 2 }
        $analyticalScore = if ($analysisPoints.ContainsKey([string]$grade.analyticalValue)) { [int]$analysisPoints[[string]$grade.analyticalValue] } else { 0 }
        $evidenceScore = if ($evidencePoints.ContainsKey([string]$grade.evidenceQuality)) { [int]$evidencePoints[[string]$grade.evidenceQuality] } else { 2 }
        if ([bool]$grade.hasQuantification) { $evidenceScore += 2 }
        if ([bool]$grade.hasDirectEvidenceLinks -and @($candidate.evidenceUrls).Count -gt 0) { $evidenceScore += 1 }
        $evidenceScore = [Math]::Min(25, $evidenceScore)
        $sourceScore = [int]$sourcePoints[$familiarity]
        $independenceScore = if ($independencePoints.ContainsKey([string]$grade.independenceQuality)) { [int]$independencePoints[[string]$grade.independenceQuality] } else { 0 }
        $score = $analyticalScore + $evidenceScore + $sourceScore + $independenceScore + $recencyScore
        $scoreCap = if ($familiarity -eq "preferred") { 89 } elseif ($familiarity -eq "established_new") { 87 } else { 84 }
        $score = [Math]::Min($scoreCap, $score)

        if ([string]$grade.directRelevance -ne "direct") { $reasons += "Not directly relevant to the verified event." }
        if (-not [bool]$grade.respondsToCompletedEvent) { $reasons += "Does not clearly respond to the completed event." }
        if ([string]$grade.language -ne "English") { $reasons += "Not presentation-ready English." }
        if ([string]$grade.tone -ne "neutral") { $reasons += "Tone is advocacy, alarmist or unclear." }
        if ([bool]$grade.isRepetition -or [string]$grade.analysisType -eq "repetition") { $reasons += "Repeats the announcement without useful analysis." }
        if ([bool]$grade.appearsGenerated) { $reasons += "Appears to be a generated roundup." }
        if ([string]$grade.analyticalValue -in @("none", "low")) { $reasons += "Insufficient incremental analytical value." }
        if ($score -lt $MinimumCommentaryScore) { $reasons += "Below the deterministic $MinimumCommentaryScore-point threshold." }

        if ($reasons.Count) {
            $rejected += [pscustomobject]@{
                eventKey = [string]$event.eventKey
                source = if ($candidate.source) { [string]$candidate.source } else { $handle }
                title = [string]$candidate.title
                url = [string]$candidate.url
                score = [int]$score
                rejectionReasons = @($reasons | Select-Object -Unique)
            }
            continue
        }

        $accepted += [pscustomobject][ordered]@{
            eventKey = [string]$event.eventKey
            source = if ($candidate.source) { [string]$candidate.source } else { $handle }
            handle = $handle
            platform = "X"
            publishedAt = $publishedUtc.ToString("o")
            url = [string]$candidate.url
            title = [string]$candidate.title
            summary = [string]$grade.summary
            incrementalValue = [string]$grade.incrementalValue
            analysisType = [string]$grade.analysisType
            commentaryScore = [int]$score
            analyticalScore = [int]$analyticalScore
            evidenceScore = [int]$evidenceScore
            sourceScore = [int]$sourceScore
            independenceScore = [int]$independenceScore
            recencyScore = [int]$recencyScore
            addsNewFacts = [bool]$grade.addsNewFacts
            hasQuantification = [bool]$grade.hasQuantification
            hasDirectEvidenceLinks = [bool]$grade.hasDirectEvidenceLinks
            language = [string]$grade.language
            tone = [string]$grade.tone
            sourceFamiliarity = $familiarity
            temporalRelation = "after_event"
            respondsToCompletedEvent = [bool]$grade.respondsToCompletedEvent
        }
    }

    $qualifyingForEvent = @($accepted | Where-Object { ([string]$_.eventKey).ToLowerInvariant() -eq $eventKey })
    $coverage += [pscustomobject]@{
        eventKey = [string]$event.eventKey
        eventTitle = [string]$event.title
        searchPasses = [int]$candidateEvent.passesRun
        candidatesFound = $candidates.Count
        candidatesGraded = $grades.Count
        qualifyingCommentary = $qualifyingForEvent.Count
        status = if ($qualifyingForEvent.Count -gt 0) { "covered" } elseif ($candidates.Count -lt $MinimumCandidatesPerEvent) { "insufficient_recall_primary_fallback" } else { "quality_screen_primary_fallback" }
    }
}

$selected = @($accepted |
    Group-Object { ([string]$_.eventKey).ToLowerInvariant() } |
    ForEach-Object {
        $_.Group | Sort-Object `
            @{ Expression = { [int]$_.commentaryScore }; Descending = $true }, `
            @{ Expression = { try { ([datetime]$_.publishedAt).Ticks } catch { 0 } }; Descending = $true } |
            Select-Object -First 1
    } |
    Sort-Object @{ Expression = { [int]$_.commentaryScore }; Descending = $true })

$totalCommentaryCandidates = @($candidateEvents | ForEach-Object { @($_.candidates) }).Count
if ($events.Count -gt 0 -and $totalCommentaryCandidates -eq 0) {
    throw "Commentary discovery returned no candidates for any verified event. The previous commentary snapshot was retained and this lane was marked incomplete."
}

$previousAcceptedUrlsByHandle = @{}
if (Test-Path -LiteralPath $outputPath) {
    try {
        $previousCommentaryFeed = [IO.File]::ReadAllText($outputPath) | ConvertFrom-Json
        foreach ($previousCommentary in @($previousCommentaryFeed.commentaries)) {
            $previousHandleKey = ([string]$previousCommentary.handle).Trim().TrimStart('@').ToLowerInvariant()
            if (-not $previousHandleKey) { continue }
            if (-not $previousAcceptedUrlsByHandle.ContainsKey($previousHandleKey)) {
                $previousAcceptedUrlsByHandle[$previousHandleKey] = @()
            }
            $previousAcceptedUrlsByHandle[$previousHandleKey] += Get-CanonicalUrl ([string]$previousCommentary.url)
        }
    } catch {}
}

$performanceByHandle = @{}
foreach ($record in $sourcePerformance) {
    $key = ([string]$record.handle).Trim().TrimStart('@').ToLowerInvariant()
    if (-not $key) { continue }
    if (-not $record.PSObject.Properties["acceptedUrls"]) {
        $seedUrls = if ($previousAcceptedUrlsByHandle.ContainsKey($key)) {
            @($previousAcceptedUrlsByHandle[$key] | Select-Object -Unique)
        } else { @() }
        $record | Add-Member -NotePropertyName acceptedUrls -NotePropertyValue $seedUrls
    }
    $performanceByHandle[$key] = $record
}
foreach ($commentary in $selected) {
    $key = ([string]$commentary.handle).Trim().TrimStart('@').ToLowerInvariant()
    if (-not $key) { continue }
    $commentaryUrl = Get-CanonicalUrl ([string]$commentary.url)
    if ($performanceByHandle.ContainsKey($key)) {
        $record = $performanceByHandle[$key]
        $knownUrls = @($record.acceptedUrls | ForEach-Object { Get-CanonicalUrl ([string]$_) })
        if ($knownUrls -contains $commentaryUrl) { continue }
        $record.acceptedUrls = @($knownUrls + $commentaryUrl | Select-Object -Unique)
        $record.acceptedCount = [int]$record.acceptedCount + 1
        $record.totalScore = [int]$record.totalScore + [int]$commentary.commentaryScore
        $record.averageScore = [Math]::Round([double]$record.totalScore / [double]$record.acceptedCount, 1)
        $record.lastAcceptedAt = $nowUtc.ToString("o")
    }
    else {
        $performanceByHandle[$key] = [pscustomobject][ordered]@{
            handle = [string]$commentary.handle
            acceptedCount = 1
            totalScore = [int]$commentary.commentaryScore
            averageScore = [double]$commentary.commentaryScore
            lastAcceptedAt = $nowUtc.ToString("o")
            acceptedUrls = @($commentaryUrl)
        }
    }
}

[IO.File]::WriteAllText($rejectionAuditPath, ($rejected | ConvertTo-Json -Depth 10), $utf8)
[IO.File]::WriteAllText($coverageAuditPath, ($coverage | ConvertTo-Json -Depth 10), $utf8)
$performanceOutput = @($performanceByHandle.Values | Sort-Object `
    @{ Expression = { [int]$_.acceptedCount }; Descending = $true }, `
    @{ Expression = { [double]$_.averageScore }; Descending = $true })
[IO.File]::WriteAllText($sourcePerformancePath, ($performanceOutput | ConvertTo-Json -Depth 10), $utf8)

$feed = [ordered]@{
    generatedAt = $nowUtc.ToString("o")
    source = "High-recall X commentary"
    eventsExamined = $events.Count
    minimumCommentaryScore = $MinimumCommentaryScore
    preferredHandles = $preferredHandles
    coverage = $coverage
    commentaries = $selected
}
[IO.File]::WriteAllText($outputPath, ($feed | ConvertTo-Json -Depth 20), $utf8)

& (Join-Path $PSScriptRoot "merge-live-feeds.ps1") | Out-Host
$coveredCount = @($coverage | Where-Object { $_.status -eq "covered" }).Count
Write-Host "Selected high-quality X commentary for $coveredCount of $($events.Count) verified events; $($rejected.Count) candidates were excluded." -ForegroundColor Green
