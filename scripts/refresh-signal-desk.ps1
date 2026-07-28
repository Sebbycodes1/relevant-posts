[CmdletBinding()]
param(
    [ValidateRange(1, 72)]
    [int]$BreakingLookbackHours = 24,

    [ValidateRange(24, 168)]
    [int]$BreakingFallbackHours = 72,

    [ValidateRange(1, 168)]
    [int]$XLookbackHours = 48,

    [ValidateRange(1, 30)]
    [int]$SubstackLookbackDays = 7
)

$ErrorActionPreference = "Continue"
$projectRoot = Split-Path -Parent $PSScriptRoot
$dashboardPath = Join-Path $projectRoot "outputs\signal-desk-live.html"
$failures = @()

Write-Host "Refreshing Relevant Posts..." -ForegroundColor Cyan

try {
    & (Join-Path $PSScriptRoot "fetch-breaking-events.ps1") -PrimaryLookbackHours $BreakingLookbackHours -FallbackLookbackHours $BreakingFallbackHours -MaxEvents 12
    if (-not $?) { throw "Breaking-event discovery did not complete." }
}
catch {
    $failures += "Breaking events: $($_.Exception.Message)"
    Write-Warning "The broad event scan failed; the other sources will still refresh."
}

try {
    & (Join-Path $PSScriptRoot "fetch-xai-signals.ps1") -LookbackHours $XLookbackHours -MaxSignals 20
    if (-not $?) { throw "X collection did not complete." }
}
catch {
    $failures += "X: $($_.Exception.Message)"
    Write-Warning "The X refresh failed; the last successful X snapshot will be retained."
}

try {
    & (Join-Path $PSScriptRoot "fetch-substack.ps1") -LimitPerSource 2 -LookbackDays $SubstackLookbackDays
    if (-not $?) { throw "Newsletter/RSS collection did not complete." }
}
catch {
    $failures += "Newsletters/RSS: $($_.Exception.Message)"
    Write-Warning "The newsletter/RSS refresh failed; the last successful snapshot will be retained."
}

try {
    & (Join-Path $PSScriptRoot "fetch-event-commentary.ps1") -MinimumCommentaryScore 70 -LookbackDays 7 -CandidatesPerEvent 10 -MinimumCandidatesPerEvent 5 -MaxDiscoveryPasses 2
    if (-not $?) { throw "Commentary enrichment did not complete." }
}
catch {
    $failures += "Commentary: $($_.Exception.Message)"
    Write-Warning "The commentary refresh failed; verified primary sources will remain available."
}

try {
    & (Join-Path $PSScriptRoot "merge-live-feeds.ps1")
    if (-not $?) { throw "The dashboard could not be rebuilt." }
}
catch {
    Write-Error "Relevant Posts could not be rebuilt. $($_.Exception.Message)"
    exit 1
}

if (Test-Path -LiteralPath $dashboardPath) {
    Start-Process -FilePath $dashboardPath
}

if ($failures.Count) {
    Write-Host "" 
    Write-Warning "The dashboard opened using the newest successful data available."
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    exit 2
}

Write-Host "Relevant Posts is current and ready." -ForegroundColor Green
