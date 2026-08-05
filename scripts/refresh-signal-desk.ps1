[CmdletBinding()]
param(
    [ValidateRange(1, 72)]
    [int]$BreakingLookbackHours = 24,

    [ValidateRange(24, 168)]
    [int]$BreakingFallbackHours = 48,

    [ValidateRange(1, 168)]
    [int]$XLookbackHours = 48,

    [ValidateRange(1, 30)]
    [int]$SubstackLookbackDays = 7,

    [switch]$CatchUp,

    [switch]$Budget,

    [switch]$Balanced,

    [ValidateRange(0.25, 100.0)]
    [double]$MaxXaiSpendUsd = 1.00,

    [ValidateRange(1, 100)]
    [int]$MaxXaiRequests = 8,

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
$xaiUnavailable = $false
. (Join-Path $PSScriptRoot "xai-cost-budget.ps1")
if ($Balanced -and ($Budget -or $CatchUp)) {
    throw "Balanced cannot be combined with Budget or CatchUp."
}
if ($Balanced) {
    # Paid calls are serialized in this profile, so the budget is rechecked after every response.
    $null = Initialize-XaiCostBudget -ProjectRoot $projectRoot -MaximumUsd $MaxXaiSpendUsd -MaximumRequests $MaxXaiRequests -ReservePerRequestUsd 0.75
}
elseif ($Budget) {
    $null = Initialize-XaiCostBudget -ProjectRoot $projectRoot -MaximumUsd $MaxXaiSpendUsd -MaximumRequests $MaxXaiRequests
}
else {
    # Full refreshes are not capped, but are still measured request-by-request.
    $null = Initialize-XaiCostBudget -ProjectRoot $projectRoot -MaximumUsd 1000 -MaximumRequests 500 -TrackOnly
}

function Test-IsBudgetStop {
    param([string]$Message)
    return ($Budget -or $Balanced) -and $Message -match 'xAI refresh budget was reached'
}

function Test-IsXaiUnavailable {
    param([string]$Message)
    return $Message -match 'used all available credits|monthly spending limit|permission-denied'
}

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
        profile = if ($Balanced) { "balanced" } elseif ($Budget) { "budget" } elseif ($CatchUp) { "catch_up" } else { "full" }
        elapsedMinutes = [Math]::Round(((Get-Date).ToUniversalTime() - $runStartedAt).TotalMinutes, 2)
        xaiUsage = Get-XaiBudgetSummary
        failures = $failures
        lanes = $laneResults
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($statusPath, ($payload | ConvertTo-Json -Depth 10), $utf8)
}

Write-Host "Refreshing Relevant Posts..." -ForegroundColor Cyan

try {
    $breakingPasses = if ($CatchUp -or $Budget -or $Balanced) { 1 } else { 2 }
    if ($Budget) {
        & (Join-Path $PSScriptRoot "fetch-breaking-events.ps1") -PrimaryLookbackHours $BreakingLookbackHours -FallbackLookbackHours $BreakingFallbackHours -StrategicRetentionHours 168 -MaxEvents 0 -MaxDiscoveryPasses 1 -MaxConcurrency 1 -Model "grok-4.3" -Economy -SkipGapAudit -SkipMerge
    }
    elseif ($Balanced) {
        & (Join-Path $PSScriptRoot "fetch-breaking-events.ps1") -PrimaryLookbackHours $BreakingLookbackHours -FallbackLookbackHours $BreakingFallbackHours -StrategicRetentionHours 168 -MaxEvents 0 -MaxDiscoveryPasses 1 -MaxConcurrency 1 -Model "grok-4.3" -Balanced -SkipGapAudit -SkipMerge
    }
    else {
        & (Join-Path $PSScriptRoot "fetch-breaking-events.ps1") -PrimaryLookbackHours $BreakingLookbackHours -FallbackLookbackHours $BreakingFallbackHours -StrategicRetentionHours 168 -MaxEvents 0 -MaxDiscoveryPasses $breakingPasses -MaxConcurrency 2 -SkipMerge
    }
    if (-not $?) { throw "Breaking-event discovery did not complete." }
    $laneResults += [ordered]@{ lane = "Breaking events"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
catch {
    if (Test-IsBudgetStop $_.Exception.Message) {
        $laneResults += [ordered]@{ lane = "Breaking events"; status = "budget_stopped"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    }
    else {
        $failures += "Breaking events: $($_.Exception.Message)"
        if (Test-IsXaiUnavailable $_.Exception.Message) { $xaiUnavailable = $true }
        $laneResults += [ordered]@{ lane = "Breaking events"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        Write-Warning "The broad event scan failed; the other sources will still refresh."
    }
}

if ($CatchUp -or $xaiUnavailable) {
    $retainedReason = if ($xaiUnavailable) { "xAI is unavailable; retaining the last complete snapshot." } else { "Using the morning snapshot." }
    $laneResults += [ordered]@{ lane = "X"; status = "retained"; message = $retainedReason; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "retained"; message = $retainedReason; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
else {
    try {
        if ($Budget) {
            & (Join-Path $PSScriptRoot "fetch-xai-signals.ps1") -LookbackHours 24 -MaxSignals 12 -MaxBatches 1 -MaxConcurrency 1 -Model "grok-4.3" -Economy -SkipMerge
        }
        elseif ($Balanced) {
            & (Join-Path $PSScriptRoot "fetch-xai-signals.ps1") -LookbackHours 36 -MaxSignals 16 -MaxBatches 1 -MaxConcurrency 1 -Model "grok-4.3" -Economy -SkipMerge
        }
        else {
            & (Join-Path $PSScriptRoot "fetch-xai-signals.ps1") -LookbackHours $XLookbackHours -MaxSignals 20 -MaxConcurrency 2 -SkipMerge
        }
        if (-not $?) { throw "X collection did not complete." }
        $laneResults += [ordered]@{ lane = "X"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    }
    catch {
        if (Test-IsBudgetStop $_.Exception.Message) {
            $laneResults += [ordered]@{ lane = "X"; status = "budget_stopped"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        }
        else {
            $failures += "X: $($_.Exception.Message)"
            $laneResults += [ordered]@{ lane = "X"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
            Write-Warning "The X refresh failed; the last successful X snapshot will be retained."
        }
    }

    try {
        if ($Budget) {
            & (Join-Path $PSScriptRoot "fetch-substack.ps1") -LimitPerSource 1 -LookbackDays ([Math]::Min(5, $SubstackLookbackDays)) -MaxConcurrency 1 -Model "grok-4.3" -Economy -SkipMerge
        }
        elseif ($Balanced) {
            & (Join-Path $PSScriptRoot "fetch-substack.ps1") -LimitPerSource 2 -LookbackDays $SubstackLookbackDays -MaxCandidates 25 -MaxConcurrency 1 -Model "grok-4.3" -Economy -SkipMerge
        }
        else {
            & (Join-Path $PSScriptRoot "fetch-substack.ps1") -LimitPerSource 2 -LookbackDays $SubstackLookbackDays -SkipMerge
        }
        if (-not $?) { throw "Newsletter/RSS collection did not complete." }
        $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
    }
    catch {
        if (Test-IsBudgetStop $_.Exception.Message) {
            $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "budget_stopped"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        }
        else {
            $failures += "Newsletters/RSS: $($_.Exception.Message)"
            $laneResults += [ordered]@{ lane = "Newsletters / RSS"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
            Write-Warning "The newsletter/RSS refresh failed; the last successful snapshot will be retained."
        }
    }
}

if ($xaiUnavailable) {
    $laneResults += [ordered]@{ lane = "Event commentary"; status = "retained"; message = "xAI is unavailable; retaining the last complete snapshot."; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
else {
try {
    if ($Budget) {
        & (Join-Path $PSScriptRoot "fetch-event-commentary.ps1") -MinimumCommentaryScore 70 -MinimumEventScore 75 -CommentaryEventLimit 2 -LookbackDays 3 -CandidatesPerEvent 5 -MinimumCandidatesPerEvent 3 -MaxDiscoveryPasses 1 -Model "grok-4.3" -Economy -SkipMerge
    }
    elseif ($Balanced) {
        & (Join-Path $PSScriptRoot "fetch-event-commentary.ps1") -MinimumCommentaryScore 70 -MinimumEventScore 75 -CommentaryEventLimit 5 -LookbackDays 2 -CandidatesPerEvent 7 -MinimumCandidatesPerEvent 4 -MaxDiscoveryPasses 1 -Model "grok-4.3" -Economy -SkipMerge
    }
    else {
        & (Join-Path $PSScriptRoot "fetch-event-commentary.ps1") -MinimumCommentaryScore 70 -MinimumEventScore 70 -CommentaryEventLimit 12 -LookbackDays 2 -CandidatesPerEvent 10 -MinimumCandidatesPerEvent 5 -MaxDiscoveryPasses 2 -SkipMerge
    }
    if (-not $?) { throw "Commentary enrichment did not complete." }
    $laneResults += [ordered]@{ lane = "Event commentary"; status = "success"; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
}
catch {
    if (Test-IsBudgetStop $_.Exception.Message) {
        $laneResults += [ordered]@{ lane = "Event commentary"; status = "budget_stopped"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        Write-Warning "The cost limit was reached; verified primary sources remain available."
    }
    else {
        $failures += "Commentary: $($_.Exception.Message)"
        $laneResults += [ordered]@{ lane = "Event commentary"; status = "failed"; message = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime().ToString("o") }
        Write-Warning "The commentary refresh failed; verified primary sources will remain available."
    }
}
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
$budgetSummary = Get-XaiBudgetSummary
$costLabel = if ([bool]$budgetSummary.costTrackingAvailable) { "`$$([double]$budgetSummary.actualCostUsd)" } else { "not returned by xAI" }
if ($Budget -or $Balanced) {
    Write-Host "xAI usage: $($budgetSummary.requestCount) of $($budgetSummary.maximumRequests) requests; cost $costLabel; stop-limit `$$($budgetSummary.maximumUsd)." -ForegroundColor DarkCyan
}
else {
    Write-Host "xAI usage: $($budgetSummary.requestCount) requests; cost $costLabel; elapsed $([Math]::Round(((Get-Date).ToUniversalTime() - $runStartedAt).TotalMinutes, 1)) minutes." -ForegroundColor DarkCyan
}
