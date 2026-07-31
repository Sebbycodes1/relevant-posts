function Get-XaiBudgetState {
    $path = [string]$env:RELEVANT_POSTS_XAI_BUDGET_PATH
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try { return [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    catch { throw "The xAI cost budget file is unreadable." }
}

function Save-XaiBudgetState {
    param($State)
    $path = [string]$env:RELEVANT_POSTS_XAI_BUDGET_PATH
    if (-not $path) { return }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($path, ($State | ConvertTo-Json -Depth 12), $utf8)
}

function Initialize-XaiCostBudget {
    param(
        [string]$ProjectRoot,
        [double]$MaximumUsd = 1.00,
        [int]$MaximumRequests = 8,
        [double]$ReservePerRequestUsd = 0.10
    )
    $path = Join-Path $ProjectRoot "work\xai-refresh-budget.json"
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $state = [ordered]@{
        startedAt = (Get-Date).ToUniversalTime().ToString("o")
        maximumUsd = [Math]::Round($MaximumUsd, 4)
        maximumRequests = $MaximumRequests
        reservePerRequestUsd = [Math]::Round($ReservePerRequestUsd, 4)
        requestCount = 0
        actualCostUsd = 0.0
        costTrackingAvailable = $true
        stoppedByBudget = $false
        requests = @()
    }
    $env:RELEVANT_POSTS_XAI_BUDGET_PATH = $path
    Save-XaiBudgetState $state
    return $path
}

function Assert-XaiBudgetAvailable {
    param([string]$Stage)
    $state = Get-XaiBudgetState
    if (-not $state) { return }
    $requestsUsed = [int]$state.requestCount
    $spent = [double]$state.actualCostUsd
    $reserve = [double]$state.reservePerRequestUsd
    if ($requestsUsed -ge [int]$state.maximumRequests -or ($spent + $reserve) -gt [double]$state.maximumUsd) {
        $state.stoppedByBudget = $true
        Save-XaiBudgetState $state
        throw "The xAI refresh budget was reached before '$Stage'."
    }
}

function Register-XaiResponseUsage {
    param(
        $Response,
        [string]$Stage
    )
    $state = Get-XaiBudgetState
    if (-not $state) { return }

    $ticks = 0.0
    $costAvailable = $false
    try {
        if ($Response.usage -and $null -ne $Response.usage.cost_in_usd_ticks) {
            $ticks = [double]$Response.usage.cost_in_usd_ticks
            $costAvailable = $true
        }
    } catch {}
    $costUsd = if ($costAvailable) { $ticks / 10000000000.0 } else { 0.0 }
    $state.requestCount = [int]$state.requestCount + 1
    $state.actualCostUsd = [Math]::Round(([double]$state.actualCostUsd + $costUsd), 6)
    if (-not $costAvailable) { $state.costTrackingAvailable = $false }
    $requestRecord = [ordered]@{
        stage = $Stage
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        costUsd = [Math]::Round($costUsd, 6)
        inputTokens = if ($Response.usage.input_tokens) { [int]$Response.usage.input_tokens } else { 0 }
        outputTokens = if ($Response.usage.output_tokens) { [int]$Response.usage.output_tokens } else { 0 }
        toolUsage = if ($Response.usage.server_side_tool_usage) { $Response.usage.server_side_tool_usage } else { $null }
    }
    $state.requests = @($state.requests) + [pscustomobject]$requestRecord
    Save-XaiBudgetState $state
}

function Get-XaiBudgetSummary {
    return Get-XaiBudgetState
}
