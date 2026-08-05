[CmdletBinding()]
param(
    [string]$BreakingFeedPath,
    [string]$CommentaryFeedPath,
    [string]$XFeedPath,
    [string]$SubstackFeedPath,
    [string]$OutputPath,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "source-trust-policy.ps1")
$nowUtc = (Get-Date).ToUniversalTime()
$visibleLookbackHours = 48
$newsletterAnalysisLookbackHours = 168
if (-not $BreakingFeedPath) { $BreakingFeedPath = Join-Path $projectRoot "outputs\live-breaking-feed.json" }
if (-not $CommentaryFeedPath) { $CommentaryFeedPath = Join-Path $projectRoot "outputs\live-commentary-feed.json" }
if (-not $XFeedPath) { $XFeedPath = Join-Path $projectRoot "outputs\live-x-feed.json" }
if (-not $SubstackFeedPath) { $SubstackFeedPath = Join-Path $projectRoot "outputs\live-substack-feed.json" }
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot "outputs\live-combined-feed.json" }
$commentaryExclusionsPath = Join-Path $PSScriptRoot "commentary-exclusions.json"
$excludedCommentaryUrls = @{}
if (Test-Path -LiteralPath $commentaryExclusionsPath) {
    $commentaryExclusions = [IO.File]::ReadAllText($commentaryExclusionsPath) | ConvertFrom-Json
    foreach ($url in @($commentaryExclusions.urls)) {
        $normalizedUrl = ([string]$url).Trim().ToLowerInvariant()
        if ($normalizedUrl) { $excludedCommentaryUrls[$normalizedUrl] = $true }
    }
}

function Repair-DisplayText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $hasEncodingMarkers = $Text.IndexOf([char]0x00C3) -ge 0 -or
        $Text.IndexOf([char]0x00C2) -ge 0 -or
        $Text.IndexOf([char]0x00E2) -ge 0 -or
        [regex]::IsMatch($Text, '[\u0080-\u009f]')
    if ($hasEncodingMarkers) {
        try {
            $repaired = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(1252).GetBytes($Text))
            if (-not $repaired.Contains([char]0xfffd)) { return $repaired }
        } catch {}
    }
    return $Text
}

function Get-TitleTokens {
    param([string]$Title)
    $stopWords = @{
        "the"=$true; "and"=$true; "for"=$true; "with"=$true; "from"=$true; "that"=$true; "this"=$true;
        "into"=$true; "over"=$true; "after"=$true; "about"=$true; "new"=$true; "its"=$true; "are"=$true;
        "how"=$true; "what"=$true; "why"=$true; "ai"=$true
    }
    $normalized = [regex]::Replace($Title.ToLowerInvariant(), '[^a-z0-9]+', ' ')
    return @($normalized.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.Length -ge 3 -and -not $stopWords.ContainsKey($_) } |
        Select-Object -Unique)
}

function Get-TitleSimilarity {
    param([string]$Left, [string]$Right)
    $leftTokens = @(Get-TitleTokens $Left)
    $rightTokens = @(Get-TitleTokens $Right)
    if ($leftTokens.Count -lt 4 -or $rightTokens.Count -lt 4) { return 0 }
    $leftSet = @{}; foreach ($token in $leftTokens) { $leftSet[$token] = $true }
    $rightSet = @{}; foreach ($token in $rightTokens) { $rightSet[$token] = $true }
    $intersection = @($leftTokens | Where-Object { $rightSet.ContainsKey($_) }).Count
    $union = @($leftTokens + $rightTokens | Select-Object -Unique).Count
    if ($union -eq 0) { return 0 }
    return [double]$intersection / [double]$union
}

function Get-EntityTokens {
    param($Entities)
    $ignored = @{ "private"=$true; "company"=$true; "labs"=$true; "laboratory"=$true; "inc"=$true; "corp"=$true; "ai"=$true }
    $tokens = @()
    foreach ($entity in @($Entities)) {
        $normalized = [regex]::Replace(([string]$entity).ToLowerInvariant(), '[^a-z0-9]+', ' ')
        $tokens += @($normalized.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) |
            Where-Object { $_.Length -ge 3 -and -not $ignored.ContainsKey($_) })
    }
    return @($tokens | Select-Object -Unique)
}

function Get-PrimaryEntityKey {
    param($Item)
    $tokens = @(Get-EntityTokens $Item.entities)
    if ($tokens.Count) { return [string]$tokens[0] }
    return ([string]$Item.source).Trim().ToLowerInvariant()
}

function Get-SourceKey {
    param($Item)
    $source = ([string]$Item.source).ToLowerInvariant()
    $source = [regex]::Replace($source, '(?i)\b(newsletter|substack|official|newsroom|investor relations|ir)\b', ' ')
    return [regex]::Replace($source, '[^a-z0-9]+', '')
}

function Get-FreshnessPriority {
    param($Item)
    try {
        $publishedUtc = ([datetime]$Item.publishedAt).ToUniversalTime()
        if ([bool]$Item.mustInclude) {
            if ($publishedUtc.TimeOfDay.TotalMinutes -eq 0) {
                $calendarDays = ($nowUtc.Date - $publishedUtc.Date).Days
                if ($calendarDays -le 0) { return 3 }
                if ($calendarDays -eq 1) { return 2 }
                if ($calendarDays -le 3) { return 1 }
                return 0
            }
            $ageHours = ($nowUtc - $publishedUtc).TotalHours
            if ($ageHours -le 24) { return 3 }
            if ($ageHours -le 48) { return 2 }
            if ($ageHours -le 72) { return 1 }
            return 0
        }
        $ageHours = ($nowUtc - $publishedUtc).TotalHours
        if ([int]$Item.score -ge 70 -and $ageHours -le 24) { return 2 }
        if ([int]$Item.score -ge 70 -and $ageHours -le 48) { return 1 }
    } catch {}
    return 0
}

function Set-ObjectProperty {
    param($Item, [string]$Name, $Value)
    if ($Item.PSObject.Properties[$Name]) {
        $Item.$Name = $Value
    }
    else {
        $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-RecommendedAnalysis {
    param($Target, $Newsletter)
    if (-not $Target -or -not $Newsletter) { return }
    $analysisValue = [string]$Newsletter.analysisValue
    if (-not ([bool]$Newsletter.isOriginalResearch) -and $analysisValue -notin @("high", "exceptional")) { return }
    $existingScore = if ($Target.PSObject.Properties["analysisScore"]) { [int]$Target.analysisScore } else { -1 }
    if ($existingScore -gt [int]$Newsletter.score) { return }
    Set-ObjectProperty $Target "recommendedAnalysis" $true
    Set-ObjectProperty $Target "analysisTitle" (Repair-DisplayText ([string]$Newsletter.title))
    Set-ObjectProperty $Target "analysisSource" (Repair-DisplayText ([string]$Newsletter.source))
    Set-ObjectProperty $Target "analysisUrl" ([string]$Newsletter.url)
    Set-ObjectProperty $Target "analysisScore" ([int]$Newsletter.score)
    Set-ObjectProperty $Target "analysisPublishedAt" ([string]$Newsletter.publishedAt)
    Set-ObjectProperty $Target "analysisAccessLevel" ([string]$Newsletter.accessLevel)
    Set-ObjectProperty $Target "analysisValue" $analysisValue
    Set-ObjectProperty $Target "analysisIncrementalValue" (Repair-DisplayText ([string]$Newsletter.incrementalValue))
    Set-ObjectProperty $Target "analysisIsOriginalResearch" ([bool]$Newsletter.isOriginalResearch)
}

$allSignals = @()
$sources = @()
$sourceFeeds = @()
$breakingFeed = $null
$commentaryFeed = $null
$selectedCommentaries = @()
$xFeed = $null
$substackFeed = $null
$fallbackRetentionHours = 72
$strategicRetentionHours = 168
if (Test-Path -LiteralPath $BreakingFeedPath) {
    $breakingFeed = [IO.File]::ReadAllText($BreakingFeedPath) | ConvertFrom-Json
    $fallbackRetentionHours = if ($breakingFeed.PSObject.Properties["fallbackLookbackHours"]) { [int]$breakingFeed.fallbackLookbackHours } else { 72 }
    $breakingSignals = @($breakingFeed.signals | Where-Object {
        try {
            $publishedUtc = ([datetime]$_.publishedAt).ToUniversalTime()
            $ageHours = ($nowUtc - $publishedUtc).TotalHours
            $ageHours -ge -2 -and $ageHours -le $visibleLookbackHours
        }
        catch { $false }
    })
    $allSignals += $breakingSignals
    $sources += "Broad event discovery"
    $sourceFeeds += [ordered]@{
        name = "Breaking events"
        generatedAt = [string]$breakingFeed.generatedAt
        signalCount = $breakingSignals.Count
    }
}
if (Test-Path -LiteralPath $XFeedPath) {
    $xFeed = [IO.File]::ReadAllText($XFeedPath) | ConvertFrom-Json
    $allSignals += @($xFeed.signals)
    $sources += "xAI X Search"
    $sourceFeeds += [ordered]@{
        name = "X"
        generatedAt = [string]$xFeed.generatedAt
        signalCount = @($xFeed.signals).Count
    }
}
if (Test-Path -LiteralPath $SubstackFeedPath) {
    $substackFeed = [IO.File]::ReadAllText($SubstackFeedPath) | ConvertFrom-Json
    $allSignals += @($substackFeed.signals)
    $sources += "Newsletters / RSS"
    $sourceFeeds += [ordered]@{
        name = "Newsletters / RSS"
        generatedAt = [string]$substackFeed.generatedAt
        signalCount = @($substackFeed.signals).Count
    }
}
if (Test-Path -LiteralPath $CommentaryFeedPath) {
    $commentaryFeed = [IO.File]::ReadAllText($CommentaryFeedPath) | ConvertFrom-Json
    $selectedCommentaries = @($commentaryFeed.commentaries | Where-Object {
        $commentaryUrl = ([string]$_.url).Trim().ToLowerInvariant()
        -not ($commentaryUrl -and $excludedCommentaryUrls.ContainsKey($commentaryUrl))
    })
    $sources += "Targeted commentary"
    $sourceFeeds += [ordered]@{
        name = "Event commentary"
        generatedAt = [string]$commentaryFeed.generatedAt
        signalCount = $selectedCommentaries.Count
    }
}
if ($allSignals.Count -eq 0) { throw "No live signals are available to merge." }
$allSignals = @($allSignals | Where-Object {
    try {
        $publishedUtc = ([datetime]$_.publishedAt).ToUniversalTime()
        $ageHours = ($nowUtc - $publishedUtc).TotalHours
        $maximumAgeHours = if ([string]$_.platform -eq "Substack" -and [bool]$_.recommendedAnalysis) {
            $newsletterAnalysisLookbackHours
        } else {
            $visibleLookbackHours
        }
        $ageHours -ge -2 -and $ageHours -le $maximumAgeHours
    }
    catch { $false }
})
if ($allSignals.Count -eq 0) { throw "No signals were published inside the strict 48-hour recency window." }
$allSignals = @($allSignals | Where-Object { -not ($_.eventType -eq "other" -and [int]$_.score -lt 70) })
if ($allSignals.Count -eq 0) { throw "No live signals cleared the event classification policy." }

# Apply a deterministic source hierarchy after every ingestion lane. This is a
# safety net against a model confusing a publisher's own report with primary
# evidence of the company or government action being reported.
$allSignals = @($allSignals | ForEach-Object { Apply-SourceTrustPolicy $_ })

foreach ($item in $allSignals) {
    if (-not [bool]$item.mustInclude) { continue }
    try {
        $eventPublishedUtc = ([datetime]$item.publishedAt).ToUniversalTime()
        $eventAgeHours = ($nowUtc - $eventPublishedUtc).TotalHours
        Set-ObjectProperty $item "isBreaking" ($eventAgeHours -ge 0 -and $eventAgeHours -le 24 -and [int]$item.score -ge 80)
        Set-ObjectProperty $item "isStrategic" $false
        Set-ObjectProperty $item "discoveryWindowHours" $(if ($eventAgeHours -le 24) { 24 } elseif ($eventAgeHours -le $fallbackRetentionHours) { $fallbackRetentionHours } else { $strategicRetentionHours })
    }
    catch {
        Set-ObjectProperty $item "isBreaking" $false
    }
}

$rankedSignals = @($allSignals | Sort-Object `
    @{ Expression = { if ([bool]$_.isBreaking) { 1 } else { 0 } }; Descending = $true }, `
    @{ Expression = { Get-FreshnessPriority $_ }; Descending = $true }, `
    @{ Expression = { [int]$_.score }; Descending = $true }, `
    @{ Expression = { try { ([datetime]$_.publishedAt).Ticks } catch { 0 } }; Descending = $true }, `
    @{ Expression = { if ([bool]$_.mustInclude) { 1 } else { 0 } }; Descending = $true })

$merged = @()
foreach ($item in $rankedSignals) {
    $key = ([string]$item.url).Trim().ToLowerInvariant()
    if (-not $key) { $key = ([string]$item.title).Trim().ToLowerInvariant() }

    $duplicate = $null
    foreach ($existing in $merged) {
        $existingKey = ([string]$existing.url).Trim().ToLowerInvariant()
        $sameUrl = $key -and $existingKey -and $key -eq $existingKey
        $sameEventKey = $false
        if ($item.eventKey -and $existing.eventKey) {
            $sameEventKey = ([string]$item.eventKey).Trim().ToLowerInvariant() -eq ([string]$existing.eventKey).Trim().ToLowerInvariant()
        }
        $nearSameEvent = $false
        if (-not $sameUrl -and -not $sameEventKey) {
            try {
                $hoursApart = [Math]::Abs((([datetime]$item.publishedAt) - ([datetime]$existing.publishedAt)).TotalHours)
                $similarity = Get-TitleSimilarity ([string]$item.title) ([string]$existing.title)
                $samePublisher = ([string]$item.source).Trim().ToLowerInvariant() -eq ([string]$existing.source).Trim().ToLowerInvariant()
                $sameCanonicalPublisher = (Get-SourceKey $item) -and (Get-SourceKey $item) -eq (Get-SourceKey $existing)
                $sameEventType = $item.eventType -and $existing.eventType -and ([string]$item.eventType).ToLowerInvariant() -eq ([string]$existing.eventType).ToLowerInvariant()
                $itemEntities = @(Get-EntityTokens $item.entities)
                $existingEntities = @(Get-EntityTokens $existing.entities)
                $entitySet = @{}; foreach ($token in $existingEntities) { $entitySet[$token] = $true }
                $entityOverlap = @($itemEntities | Where-Object { $entitySet.ContainsKey($_) }).Count
                $itemTitleTokens = @(Get-TitleTokens ([string]$item.title))
                $existingTitleTokens = @(Get-TitleTokens ([string]$existing.title))
                $titleSet = @{}; foreach ($token in $existingTitleTokens) { $titleSet[$token] = $true }
                $titleOverlap = @($itemTitleTokens | Where-Object { $titleSet.ContainsKey($_) }).Count
                $newsletterPair = ([string]$item.platform -eq "Substack" -and [bool]$item.recommendedAnalysis) -or
                    ([string]$existing.platform -eq "Substack" -and [bool]$existing.recommendedAnalysis)
                $nearSameEvent = $hoursApart -le 96 -and (
                    $similarity -ge 0.58 -or
                    ($samePublisher -and $similarity -ge 0.42) -or
                    ($sameCanonicalPublisher -and $hoursApart -le 24 -and $titleOverlap -ge 3) -or
                    ($entityOverlap -ge 2 -and $hoursApart -le 48 -and $titleOverlap -ge 2) -or
                    ($sameEventType -and $entityOverlap -gt 0 -and ($similarity -ge 0.20 -or ($similarity -ge 0.15 -and $titleOverlap -ge 2)))
                )
                if (-not $nearSameEvent -and $newsletterPair -and $hoursApart -le $newsletterAnalysisLookbackHours) {
                    $nearSameEvent = ($sameCanonicalPublisher -and $titleOverlap -ge 2) -or
                        ($sameEventType -and $entityOverlap -gt 0 -and $titleOverlap -ge 2)
                }
            } catch {}
        }
        if ($sameUrl -or $sameEventKey -or $nearSameEvent) { $duplicate = $existing; break }
    }
    if ($duplicate) {
        $itemIsNewsletter = [string]$item.platform -eq "Substack"
        $duplicateIsNewsletter = [string]$duplicate.platform -eq "Substack"
        if ($itemIsNewsletter -and -not $duplicateIsNewsletter) {
            Set-RecommendedAnalysis $duplicate $item
        }
        elseif ($duplicateIsNewsletter -and -not $itemIsNewsletter) {
            foreach ($field in @("source", "handle", "title", "summary", "implication", "whyNow", "evidenceSummary")) {
                $item.$field = Repair-DisplayText ([string]$item.$field)
            }
            Set-RecommendedAnalysis $item $duplicate
            Set-ObjectProperty $item "relatedSources" @($duplicate.relatedSources + [string]$duplicate.source + [string]$item.source | Where-Object { $_ } | Select-Object -Unique)
            Set-ObjectProperty $item "relatedUrls" @($duplicate.relatedUrls + [string]$duplicate.url + [string]$item.url | Where-Object { $_ } | Select-Object -Unique)
            Set-ObjectProperty $item "relatedCoverageCount" @($item.relatedUrls).Count
            Set-ObjectProperty $item "corroboratingUrls" @($item.corroboratingUrls + $duplicate.corroboratingUrls |
                Where-Object { $_ -and ([string]$_).Trim().ToLowerInvariant() -ne ([string]$item.url).Trim().ToLowerInvariant() } |
                Select-Object -Unique | Select-Object -First 4)
            Set-ObjectProperty $item "hasIndependentConfirmation" ([bool]$item.hasIndependentConfirmation -or [bool]$duplicate.hasIndependentConfirmation)
            Set-ObjectProperty $item "isBreaking" ([bool]$item.isBreaking -or [bool]$duplicate.isBreaking)
            Set-ObjectProperty $item "mustInclude" ([bool]$item.mustInclude -or [bool]$duplicate.mustInclude)
            $duplicateIndex = [array]::IndexOf($merged, $duplicate)
            if ($duplicateIndex -ge 0) { $merged[$duplicateIndex] = $item }
            continue
        }
        $duplicate.relatedSources = @($duplicate.relatedSources + [string]$item.source | Where-Object { $_ } | Select-Object -Unique)
        $duplicate.relatedUrls = @($duplicate.relatedUrls + [string]$item.url | Where-Object { $_ } | Select-Object -Unique)
        $duplicate.relatedCoverageCount = $duplicate.relatedUrls.Count
        $coverageUrlForCorroboration = if ($itemIsNewsletter) { $null } else { [string]$item.url }
        $additionalCorroboration = @($duplicate.corroboratingUrls + $item.corroboratingUrls + $coverageUrlForCorroboration |
            Where-Object { $_ -and ([string]$_).Trim().ToLowerInvariant() -ne ([string]$duplicate.url).Trim().ToLowerInvariant() } |
            Select-Object -Unique |
            Select-Object -First 4)
        Set-ObjectProperty $duplicate "corroboratingUrls" $additionalCorroboration
        Set-ObjectProperty $duplicate "hasIndependentConfirmation" ([bool]$duplicate.hasIndependentConfirmation -or [bool]$item.hasIndependentConfirmation)
        Set-ObjectProperty $duplicate "isBreaking" ([bool]$duplicate.isBreaking -or [bool]$item.isBreaking)
        Set-ObjectProperty $duplicate "mustInclude" ([bool]$duplicate.mustInclude -or [bool]$item.mustInclude)
        continue
    }

    foreach ($field in @("source", "handle", "title", "summary", "implication", "whyNow", "evidenceSummary")) {
        $item.$field = Repair-DisplayText ([string]$item.$field)
    }
    if (-not $item.PSObject.Properties["relatedSources"]) { $item | Add-Member -NotePropertyName relatedSources -NotePropertyValue @([string]$item.source) }
    if (-not $item.PSObject.Properties["relatedUrls"]) { $item | Add-Member -NotePropertyName relatedUrls -NotePropertyValue @([string]$item.url) }
    if (-not $item.PSObject.Properties["relatedCoverageCount"]) { $item | Add-Member -NotePropertyName relatedCoverageCount -NotePropertyValue 1 }
    $merged += $item
}

$commentaryByEventKey = @{}
foreach ($commentary in $selectedCommentaries) {
    $commentaryKey = ([string]$commentary.eventKey).Trim().ToLowerInvariant()
    if (-not $commentaryKey) { continue }
    if (-not $commentaryByEventKey.ContainsKey($commentaryKey) -or [int]$commentary.commentaryScore -gt [int]$commentaryByEventKey[$commentaryKey].commentaryScore) {
        $commentaryByEventKey[$commentaryKey] = $commentary
    }
}

foreach ($item in $merged) {
    $eventKey = ([string]$item.eventKey).Trim().ToLowerInvariant()
    if (-not $eventKey -or -not $commentaryByEventKey.ContainsKey($eventKey)) { continue }
    $commentary = $commentaryByEventKey[$eventKey]

    Set-ObjectProperty $item "primarySourceUrl" ([string]$item.url)
    Set-ObjectProperty $item "primarySourceName" ([string]$item.source)
    Set-ObjectProperty $item "primarySourcePlatform" ([string]$item.platform)
    Set-ObjectProperty $item "eventPublishedAt" ([string]$item.publishedAt)
    Set-ObjectProperty $item "featuredCommentary" $true
    Set-ObjectProperty $item "commentaryTitle" (Repair-DisplayText ([string]$commentary.title))
    Set-ObjectProperty $item "commentarySummary" (Repair-DisplayText ([string]$commentary.summary))
    Set-ObjectProperty $item "commentaryIncrementalValue" (Repair-DisplayText ([string]$commentary.incrementalValue))
    Set-ObjectProperty $item "commentaryAnalysisType" ([string]$commentary.analysisType)
    Set-ObjectProperty $item "commentaryScore" ([int]$commentary.commentaryScore)
    Set-ObjectProperty $item "commentarySourceFamiliarity" ([string]$commentary.sourceFamiliarity)
    Set-ObjectProperty $item "commentaryHasDirectEvidenceLinks" ([bool]$commentary.hasDirectEvidenceLinks)
    Set-ObjectProperty $item "commentarySource" (Repair-DisplayText ([string]$commentary.source))
    Set-ObjectProperty $item "commentaryHandle" ([string]$commentary.handle)
    Set-ObjectProperty $item "commentaryPlatform" ([string]$commentary.platform)
    Set-ObjectProperty $item "commentaryPublishedAt" ([string]$commentary.publishedAt)
    Set-ObjectProperty $item "commentaryUrl" ([string]$commentary.url)

    $item.relatedSources = @($item.relatedSources + [string]$commentary.source | Where-Object { $_ } | Select-Object -Unique)
    $item.relatedUrls = @($item.relatedUrls + [string]$commentary.url | Where-Object { $_ } | Select-Object -Unique)
    $item.relatedCoverageCount = $item.relatedUrls.Count
}

foreach ($item in $merged) {
    foreach ($analysisField in @("analysisTitle", "analysisSource", "analysisIncrementalValue")) {
        if ($item.PSObject.Properties[$analysisField]) {
            Set-ObjectProperty $item $analysisField (Repair-DisplayText ([string]$item.$analysisField))
        }
    }
}

# Older long-form work can enrich a current event for up to one week, but it
# never becomes an old standalone card on the current-news feed.
$merged = @($merged | Where-Object {
    if ([string]$_.platform -ne "Substack") { return $true }
    try { return ($nowUtc - ([datetime]$_.publishedAt).ToUniversalTime()).TotalHours -le $visibleLookbackHours }
    catch { return $false }
})

$frontPageLimit = [Math]::Min(8, $merged.Count)
$frontPage = @()
$deferred = @()
$issuerCounts = @{}
foreach ($item in $merged) {
    if ($frontPage.Count -ge $frontPageLimit) {
        $deferred += $item
        continue
    }
    $issuerKey = Get-PrimaryEntityKey $item
    $issuerCount = if ($issuerCounts.ContainsKey($issuerKey)) { [int]$issuerCounts[$issuerKey] } else { 0 }
    $independentlyMaterial = [bool]$item.mustInclude
    if ($independentlyMaterial -or $issuerCount -eq 0) {
        $frontPage += $item
        $issuerCounts[$issuerKey] = $issuerCount + 1
    }
    else {
        $deferred += $item
    }
}
if ($frontPage.Count -lt $frontPageLimit) {
    $needed = $frontPageLimit - $frontPage.Count
    $fillers = @($deferred | Select-Object -First $needed)
    $frontPage += $fillers
    $fillerKeys = @{}; foreach ($filler in $fillers) { $fillerKeys[([string]$filler.url).ToLowerInvariant()] = $true }
    $deferred = @($deferred | Where-Object { -not $fillerKeys.ContainsKey(([string]$_.url).ToLowerInvariant()) })
}
$merged = @($frontPage + $deferred)

$qualifiedSignalCount = $merged.Count
$presentationSignalLimit = 30
if ($merged.Count -gt $presentationSignalLimit) {
    $merged = @($merged | Select-Object -First $presentationSignalLimit)
}

$sourceDates = @($sourceFeeds | ForEach-Object {
    try { ([datetime]$_.generatedAt).ToUniversalTime() } catch {}
} | Where-Object { $_ })
$publishedDates = @($merged | ForEach-Object {
    try { ([datetime]$_.publishedAt).ToUniversalTime() } catch {}
} | Where-Object { $_ })
$sourceUpdatedAt = if ($sourceDates.Count) { ($sourceDates | Sort-Object -Descending | Select-Object -First 1).ToString("o") } else { $null }
$oldestSourceAt = if ($sourceDates.Count) { ($sourceDates | Sort-Object | Select-Object -First 1).ToString("o") } else { $null }
$newestPublishedAt = if ($publishedDates.Count) { ($publishedDates | Sort-Object -Descending | Select-Object -First 1).ToString("o") } else { $null }

$combined = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    sourceUpdatedAt = $sourceUpdatedAt
    oldestSourceAt = $oldestSourceAt
    newestPublishedAt = $newestPublishedAt
    staleAfterHours = 36
    qualifiedSignalCount = $qualifiedSignalCount
    presentationSignalLimit = $presentationSignalLimit
    source = ($sources -join " + ")
    sourceFeeds = $sourceFeeds
    signals = $merged
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, ($combined | ConvertTo-Json -Depth 20), $utf8)

if (-not $SkipBuild) {
    $builder = Join-Path $PSScriptRoot "build-live-dashboard.ps1"
    & $builder -FeedPath $OutputPath | Out-Host
}
Write-Host "Merged $($merged.Count) signals into the live dashboard." -ForegroundColor Green
