$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot ".env.local"
$secureToken = Read-Host "Paste your X API bearer token (it will not be displayed)" -AsSecureString
$tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)

try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "No token was entered."
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($envPath, "X_BEARER_TOKEN=$token`r`n", $utf8)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    Remove-Variable token -ErrorAction SilentlyContinue
}

Write-Host "X API access is configured for Signal Desk. Restart the dashboard to use live X posts." -ForegroundColor Green
Read-Host "Press Enter to close"
