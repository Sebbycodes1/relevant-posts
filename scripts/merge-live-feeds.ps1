[CmdletBinding()]
param(
    [string]$BreakingFeedPath,
    [string]$CommentaryFeedPath,
    [string]$XFeedPath,
    [string]$SubstackFeedPath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $BreakingFeedPath) { $BreakingFeedPath = Join-Path $projectRoot "outputs\live-breaking-feed.json" }
if (-not $CommentaryFeedPath) { $CommentaryFeedPath = Join-Path $projectRoot "outputs\live-commentary-feed.json" }
if (-not $XFeedPath) { $XFeedPath = Join-Path $projectRoot "outputs\live-x-feed.json" }
if (-not $SubstackFeedPath) { $SubstackFeedPath = Join-Path $projectRoot "outputs\live-substack-feed.json" }
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot "outputs\live-combined-feed.json" }

function Repair-DisplayText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $hasEncodingMarkers = $Text.IndexOf([char]0x00C3) -ge 0 -or
        $Text.IndexOf([char]0x00C2) -ge 0 -or
        $Text.IndexOf([char]0x00E2) -ge 0 -or
        [regex]::IsMatch($Text, '[\u0080-\u009f]')
    if ($hasEncodingMarkers) {
        try {
            $repaired = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($Text))
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

function Set-ObjectProperty {
    param($Item, [string]$Name, $Value)
    if ($Item.PSObject.Properties[$Name]) {
        $Item.$Name = $Value
    }
    else {
        $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

$allSignals = @()
$sources = @()
$sourceFeeds = @()
$breakingFeed = $null
$commentaryFeed = $null
$selectedCommentaries = @()
$xFeed = $null
$substackFeed = $null
if (Test-Path -LiteralPath $BreakingFeedPath) {
    $breakingFeed = [IO.File]::ReadAllText($BreakingFeedPath) | ConvertFrom-Json
    $breakingSignals = @($breakingFeed.signals | Where-Object {
        try {
            $publishedUtc = ([datetime]$_.publishedAt).ToUniversalTime()
            $maximumAge = if ($publishedUtc.TimeOfDay.TotalMinutes -eq 0) { 96 } else { 80 }
            ((Get-Date).ToUniversalTime() - $publishedUtc).TotalHours -le $maximumAge
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
    $selectedCommentaries = @($commentaryFeed.commentaries)
    $sources += "Targeted commentary"
    $sourceFeeds += [ordered]@{
        name = "Event commentary"
        generatedAt = [string]$commentaryFeed.generatedAt
        signalCount = $selectedCommentaries.Count
    }
}
if ($allSignals.Count -eq 0) { throw "No live signals are available to merge." }
$allSignals = @($allSignals | Where-Object { -not ($_.eventType -eq "other" -and [int]$_.score -lt 70) })
if ($allSignals.Count -eq 0) { throw "No live signals cleared the event classification policy." }

$rankedSignals = @($allSignals | Sort-Object `
    @{ Expression = { if ([bool]$_.isBreaking) { 1 } else { 0 } }; Descending = $true }, `
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
                $sameEventType = $item.eventType -and $existing.eventType -and ([string]$item.eventType).ToLowerInvariant() -eq ([string]$existing.eventType).ToLowerInvariant()
                $itemEntities = @(Get-EntityTokens $item.entities)
                $existingEntities = @(Get-EntityTokens $existing.entities)
                $entitySet = @{}; foreach ($token in $existingEntities) { $entitySet[$token] = $true }
                $entityOverlap = @($itemEntities | Where-Object { $entitySet.ContainsKey($_) }).Count
                $itemTitleTokens = @(Get-TitleTokens ([string]$item.title))
                $existingTitleTokens = @(Get-TitleTokens ([string]$existing.title))
                $titleSet = @{}; foreach ($token in $existingTitleTokens) { $titleSet[$token] = $true }
                $titleOverlap = @($itemTitleTokens | Where-Object { $titleSet.ContainsKey($_) }).Count
                $nearSameEvent = $hoursApart -le 96 -and (
                    $similarity -ge 0.58 -or
                    ($samePublisher -and $similarity -ge 0.42) -or
                    ($sameEventType -and $entityOverlap -gt 0 -and ($similarity -ge 0.20 -or ($similarity -ge 0.15 -and $titleOverlap -ge 2)))
                )
            } catch {}
        }
        if ($sameUrl -or $sameEventKey -or $nearSameEvent) { $duplicate = $existing; break }
    }
    if ($duplicate) {
        $duplicate.relatedSources = @($duplicate.relatedSources + [string]$item.source | Where-Object { $_ } | Select-Object -Unique)
        $duplicate.relatedUrls = @($duplicate.relatedUrls + [string]$item.url | Where-Object { $_ } | Select-Object -Unique)
        $duplicate.relatedCoverageCount = $duplicate.relatedUrls.Count
        $additionalCorroboration = @($duplicate.corroboratingUrls + $item.corroboratingUrls + [string]$item.url |
            Where-Object { $_ -and ([string]$_).Trim().ToLowerInvariant() -ne ([string]$duplicate.url).Trim().ToLowerInvariant() } |
            Select-Object -Unique |
            Select-Object -First 4)
        Set-ObjectProperty $duplicate "corroboratingUrls" $additionalCorroboration
        Set-ObjectProperty $duplicate "hasIndependentConfirmation" ([bool]$duplicate.hasIndependentConfirmation -or [bool]$item.hasIndependentConfirmation -or $duplicate.relatedSources.Count -gt 1)
        Set-ObjectProperty $duplicate "isBreaking" ([bool]$duplicate.isBreaking -or [bool]$item.isBreaking)
        Set-ObjectProperty $duplicate "mustInclude" ([bool]$duplicate.mustInclude -or [bool]$item.mustInclude)
        continue
    }

    foreach ($field in @("title", "summary", "implication")) {
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

    $item.source = Repair-DisplayText ([string]$commentary.source)
    $item.handle = [string]$commentary.handle
    $item.platform = [string]$commentary.platform
    $item.publishedAt = [string]$commentary.publishedAt
    $item.url = [string]$commentary.url
    $item.relatedSources = @($item.relatedSources + [string]$commentary.source | Where-Object { $_ } | Select-Object -Unique)
    $item.relatedUrls = @($item.relatedUrls + [string]$commentary.url | Where-Object { $_ } | Select-Object -Unique)
    $item.relatedCoverageCount = $item.relatedUrls.Count
}

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
    source = ($sources -join " + ")
    sourceFeeds = $sourceFeeds
    signals = $merged
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, ($combined | ConvertTo-Json -Depth 20), $utf8)

$builder = Join-Path $PSScriptRoot "build-live-dashboard.ps1"
& $builder -FeedPath $OutputPath | Out-Host
Write-Host "Merged $($merged.Count) signals into the live dashboard." -ForegroundColor Green
