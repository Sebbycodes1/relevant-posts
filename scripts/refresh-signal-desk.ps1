[CmdletBinding()]
param(
    [ValidateRange(1, 72)]
    [int]$BreakingLookbackHours = 24,

    [ValidateRange(24, 168)]
    [int]$BreakingFallbackHours = 72,

    [ValidateRange(1, 168)]
    [int]$XLookbackHours = 48,

    [ValidateRange(1, 30)]
    [int]$SubstackLookbackDays = 7,

    [switch]$CatchUp,

    [switch]$Publish,

    [switch]$SkipOpen
)

$ErrorActionPreference = "Continue"
$projectRoot = Split-Path -Parent $PSScriptRoot
$dashboardPath = Join-Path $projectRoot "outputs\signal-desk-live.html"
$statusPath = Join-Path $projectRoot "work\last-refresh-status.json"
$runStartedAt = (Get-Date).ToUniversalTime()
$failures = @()
$laneResults = @()

function Write-RefreshStatus {
    param(
        [string]$Status,
        [bool]$Published = $false,
        [string]$PublishMessage = ""
    )

    $statusDirectory = Split-Path -Parent $statusPath
    New-Item -ItemType Directory -Path $statusDirectory -Force | Out-Null
    $payload = [ordered]@{
        status = $Status
        startedAt = $runStartedAt.ToString("o")
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        published = $Published
        publishMessage = $PublishMessage
        profile = if ($CatchUp) { "catch_up" } else { "full" }
        failures = $failures
        lanes = $laneResults
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($statusPath, ($payload | ConvertTo-Json -Depth 10), $utf8)
}

Write-Host "Refreshing Relevant Posts..." -ForegroundColor Cyan

try {
    $breakingPasses = if ($CatchUp) { 1 } else { 2 }
    & (Join-Path $PSScriptRoot "fetch-breaking-events.ps1") -PrimaryLookbackHours $BreakingLookbackHours -FallbackLookbackHours $BreakingFallbackHours -MaxEvents 0 -MaxDiscoveryPasses $breakingPasses
    if (-not $?) { throw "Breaking-event discovery did not complete." }
    $laneResults += [ordered]@{ lane = "Breaking events"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
catch {
    $failures += "Breaking events: $($_.Exception.Message)"
    $laneResults += [ordered]@{ lane = "Breaking events"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    Write-Warning "The broad event scan failed; the other sources will still refresh."
}

if ($CatchUp) {
    $laneResults += [ordered]@{ lane = "X"; status = "retained"; message = "Using the morning X account scan."; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "retained"; message = "Using the morning newsletter/RSS scan."; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
else {
    try {
        & (Join-Path $PSScriptRoot "fetch-xai-signals.ps1") -LookbackHours $XLookbackHours -MaxSignals 20
        if (-not $?) { throw "X collection did not complete." }
        $laneResults += [ordered]@{ lane = "X"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    }
    catch {
        $failures += "X: $($_.Exception.Message)"
        $laneResults += [ordered]@{ lane = "X"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        Write-Warning "The X refresh failed; the last successful X snapshot will be retained."
    }

    try {
        & (Join-Path $PSScriptRoot "fetch-substack.ps1") -LimitPerSource 2 -LookbackDays $SubstackLookbackDays
        if (-not $?) { throw "Newsletter/RSS collection did not complete." }
        $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    }
    catch {
        $failures += "Newsletters/RSS: $($_.Exception.Message)"
        $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        Write-Warning "The newsletter/RSS refresh failed; the last successful snapshot will be retained."
    }
}

try {
    & (Join-Path $PSScriptRoot "fetch-event-commentary.ps1") -MinimumCommentaryScore 70 -MinimumEventScore 70 -CommentaryEventLimit 30 -LookbackDays 7 -CandidatesPerEvent 10 -MinimumCandidatesPerEvent 5 -MaxDiscoveryPasses 2
    if (-not $?) { throw "Commentary enrichment did not complete." }
    $laneResults += [ordered]@{ lane = "Event commentary"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
catch {
    $failures += "Commentary: $($_.Exception.Message)"
    $laneResults += [ordered]@{ lane = "Event commentary"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    Write-Warning "The commentary refresh failed; verified primary sources will remain available."
}

try {
    & (Join-Path $PSScriptRoot "merge-live-feeds.ps1")
    if (-not $?) { throw "The dashboard could not be rebuilt." }
}
catch {
    $failures += "Dashboard: $($_.Exception.Message)"
    Write-RefreshStatus -Status "failed"
    Write-Error "Relevant Posts could not be rebuilt. $($_.Exception.Message)"
    exit 1
}

if (-not $SkipOpen -and (Test-Path -LiteralPath $dashboardPath)) {
    Start-Process -FilePath $dashboardPath
}

if ($failures.Count) {
    Write-RefreshStatus -Status "partial"
    Write-Host "" 
    Write-Warning "The dashboard opened using the newest successful data available."
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    if ($Publish) {
        Write-Warning "The public dashboard was not changed because at least one source lane did not complete."
    }
    exit 2
}

if ($Publish) {
    try {
        & (Join-Path $PSScriptRoot "publish-dashboard.ps1")
        if (-not $?) { throw "GitHub publishing did not complete." }
        Write-RefreshStatus -Status "success" -Published $true -PublishMessage "Published to GitHub Pages."
    }
    catch {
        $failures += "Publishing: $($_.Exception.Message)"
        Write-RefreshStatus -Status "publish_failed" -PublishMessage $_.Exception.Message
        Write-Error "The feed refreshed successfully, but the public dashboard was not updated. $($_.Exception.Message)"
        exit 1
    }
}
else {
    Write-RefreshStatus -Status "success"
}

Write-Host "Relevant Posts is current and ready." -ForegroundColor Green
