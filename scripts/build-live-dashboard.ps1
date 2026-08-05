[CmdletBinding()]
param(
    [string]$TemplatePath,
    [string]$FeedPath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $TemplatePath) {
    $publishedTemplatePath = Join-Path $projectRoot "docs\index.html"
    $offlineTemplatePath = Join-Path $projectRoot "outputs\signal-desk-offline.html"
    $TemplatePath = if (Test-Path -LiteralPath $publishedTemplatePath) { $publishedTemplatePath } else { $offlineTemplatePath }
}
if (-not $FeedPath) { $FeedPath = Join-Path $projectRoot "outputs\live-x-feed.json" }
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot "outputs\signal-desk-live.html" }

if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "The offline dashboard template is missing." }
if (-not (Test-Path -LiteralPath $FeedPath)) { throw "The live feed JSON is missing." }

$html = [IO.File]::ReadAllText($TemplatePath)
$feed = [IO.File]::ReadAllText($FeedPath) | ConvertFrom-Json
$signals = @($feed.signals)
if ($signals.Count -eq 0) { throw "The live feed contains no signals." }

$signalsJson = $signals | ConvertTo-Json -Depth 20 -Compress
$signalsJson = $signalsJson.Replace("&", "\u0026").Replace("<", "\u003c").Replace(">", "\u003e")

$feedMeta = [ordered]@{
    generatedAt = [string]$feed.generatedAt
    sourceUpdatedAt = if ($feed.PSObject.Properties["sourceUpdatedAt"]) { [string]$feed.sourceUpdatedAt } else { [string]$feed.generatedAt }
    oldestSourceAt = if ($feed.PSObject.Properties["oldestSourceAt"]) { [string]$feed.oldestSourceAt } else { [string]$feed.generatedAt }
    newestPublishedAt = if ($feed.PSObject.Properties["newestPublishedAt"]) { [string]$feed.newestPublishedAt } else { "" }
    staleAfterHours = if ($feed.PSObject.Properties["staleAfterHours"]) { [int]$feed.staleAfterHours } else { 36 }
    sourceFeeds = if ($feed.PSObject.Properties["sourceFeeds"]) { @($feed.sourceFeeds) } else { @() }
}
$feedMetaJson = $feedMeta | ConvertTo-Json -Depth 10 -Compress
$feedMetaJson = $feedMetaJson.Replace("&", "\u0026").Replace("<", "\u003c").Replace(">", "\u003e")

$dataStart = $html.IndexOf("    const demoSignals =")
$sourceStart = $html.IndexOf("    const sources =", $dataStart)
if ($dataStart -lt 0 -or $sourceStart -lt 0) { throw "The dashboard data markers could not be found." }

$updated = $html.Substring(0, $dataStart) +
    "    const demoSignals = " + $signalsJson + ";`r`n`r`n" +
    "    const feedMeta = " + $feedMetaJson + ";`r`n`r`n" +
    $html.Substring($sourceStart)

$sourceUpdatedAt = if ($feedMeta.sourceUpdatedAt) { [datetime]$feedMeta.sourceUpdatedAt } else { [datetime]$feed.generatedAt }
$sourceUpdatedLocal = $sourceUpdatedAt.ToLocalTime().ToString("MMM d, yyyy h:mm tt")
$hasX = @($signals | Where-Object { $_.platform -eq "X" }).Count -gt 0
$hasSubstack = @($signals | Where-Object { $_.platform -eq "Substack" }).Count -gt 0
$hasWeb = @($signals | Where-Object { $_.platform -eq "Web" }).Count -gt 0
$snapshotLabel = if ($hasWeb -and $hasX -and $hasSubstack) {
    "Broad web + X + newsletters / RSS"
}
elseif ($hasWeb -and $hasX) {
    "Broad web + X"
}
elseif ($hasWeb -and $hasSubstack) {
    "Broad web + newsletters / RSS"
}
elseif ($hasX -and $hasSubstack) {
    "X + newsletters / RSS"
}
elseif ($hasWeb) {
    "Broad web"
}
elseif ($hasSubstack) {
    "Newsletters / RSS"
}
else {
    "X"
}

$updated = [regex]::Replace($updated, '<title>Relevant Posts[^<]*</title>', '<title>Relevant Posts - AI Stack Brief</title>', 1)
$updated = [regex]::Replace($updated, '<div class="eyebrow">Tuesday intelligence brief[^<]*</div>', "<div class=`"eyebrow`">$snapshotLabel</div>", 1)
$updated = [regex]::Replace($updated, '<span id="feedMode">[^<]*</span>', "<span id=`"feedMode`">$snapshotLabel - sources refreshed $sourceUpdatedLocal</span>", 1)
$modeLabel = "$snapshotLabel - sources refreshed $sourceUpdatedLocal"
$updated = [regex]::Replace(
    $updated,
    '(?s)(const state\s*=\s*\{.*?\bmode:\s*)"[^"]*"',
    [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $match.Groups[1].Value + '"' + $modeLabel.Replace('\', '\\').Replace('"', '\"') + '"'
    },
    1
)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, $updated, $utf8)
Write-Host "Created one-click live dashboard: $OutputPath" -ForegroundColor Green
