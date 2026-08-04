[CmdletBinding()]
param(
    [string]$DashboardPath,
    [string]$FeedPath,
    [string]$PublishedPath,
    [string]$CommitMessage,
    [switch]$SkipGit
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $DashboardPath) { $DashboardPath = Join-Path $projectRoot "outputs\signal-desk-live.html" }
if (-not $FeedPath) { $FeedPath = Join-Path $projectRoot "outputs\live-combined-feed.json" }
if (-not $PublishedPath) { $PublishedPath = Join-Path $projectRoot "docs\index.html" }
if (-not $CommitMessage) { $CommitMessage = "Refresh Relevant Posts - $((Get-Date).ToString('yyyy-MM-dd'))" }

if (-not (Test-Path -LiteralPath $DashboardPath)) { throw "The refreshed dashboard file is missing." }
if (-not (Test-Path -LiteralPath $FeedPath)) { throw "The combined feed file is missing." }

$feed = [IO.File]::ReadAllText($FeedPath) | ConvertFrom-Json
$signals = @($feed.signals)
if ($signals.Count -eq 0) { throw "The combined feed is empty; nothing was published." }

$staleAfterHours = if ($feed.PSObject.Properties["staleAfterHours"]) { [int]$feed.staleAfterHours } else { 36 }
$nowUtc = (Get-Date).ToUniversalTime()
$staleLanes = @($feed.sourceFeeds | Where-Object {
    try {
        ($nowUtc - ([datetime]$_.generatedAt).ToUniversalTime()).TotalHours -gt $staleAfterHours
    }
    catch { $true }
})
if ($staleLanes.Count) {
    throw "Publishing stopped because these source lanes are stale or have invalid timestamps: $(@($staleLanes.name) -join ', ')."
}

$html = [IO.File]::ReadAllText($DashboardPath)
$signalMatch = [regex]::Match($html, '(?s)const demoSignals = (\[.*?\]);\s*const feedMeta =')
if (-not $signalMatch.Success) { throw "The dashboard does not contain a readable embedded feed." }
$embeddedSignals = $signalMatch.Groups[1].Value | ConvertFrom-Json
$embeddedSignalCount = if ($embeddedSignals -is [array]) { $embeddedSignals.Count } else { 1 }
if ($embeddedSignalCount -ne $signals.Count) {
    throw "The dashboard contains $embeddedSignalCount signals but the combined feed contains $($signals.Count)."
}

$publishedDirectory = Split-Path -Parent $PublishedPath
New-Item -ItemType Directory -Path $publishedDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($PublishedPath, $html, $utf8)
Write-Host "Prepared the current dashboard for sharing." -ForegroundColor Green

if ($SkipGit) { return }

Push-Location $projectRoot
try {
    $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "The Git branch could not be read." }
    if ($branch -ne "main") { throw "Publishing is only allowed from the main branch; the current branch is '$branch'." }

    $otherChanges = @(& git status --porcelain --untracked-files=no | Where-Object {
        $_ -notmatch '^[ MARC?]{2}\s+docs/index\.html$'
    })
    if ($otherChanges.Count) {
        throw "Publishing stopped because the project has other uncommitted tracked changes."
    }

    & git add -- docs/index.html
    if ($LASTEXITCODE -ne 0) { throw "The refreshed dashboard could not be staged." }

    & git diff --cached --quiet -- docs/index.html
    $hasChanges = $LASTEXITCODE -ne 0
    if ($hasChanges) {
        & git commit -m $CommitMessage
        if ($LASTEXITCODE -ne 0) { throw "The refreshed dashboard could not be committed." }
    }
    else {
        Write-Host "The published dashboard already matches the refreshed file." -ForegroundColor DarkCyan
    }

    & git push origin main
    if ($LASTEXITCODE -ne 0) { throw "The refreshed dashboard could not be pushed to GitHub." }
}
finally {
    Pop-Location
}

Write-Host "Relevant Posts was published to GitHub Pages." -ForegroundColor Green
