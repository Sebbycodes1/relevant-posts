$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$secretDirectory = Join-Path $projectRoot ".secrets"
$secretPath = Join-Path $secretDirectory "xai-api-key.local"

Write-Host "Signal Desk - local xAI setup" -ForegroundColor Cyan
Write-Host "The key will stay in Signal Desk's local Git-ignored secrets folder and will not be displayed."
Write-Host "Do not use this prompt on a shared Windows account." -ForegroundColor DarkYellow
Write-Host ""

$secureKey = Read-Host "Paste the raw xAI API key only (no quotes and no 'Bearer' prefix)" -AsSecureString
if ($secureKey.Length -lt 10) {
    throw "The key was empty or unexpectedly short. Nothing was saved."
}

New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
$keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer).Trim()
    if (($plainKey.StartsWith('"') -and $plainKey.EndsWith('"')) -or ($plainKey.StartsWith("'") -and $plainKey.EndsWith("'"))) {
        $plainKey = $plainKey.Substring(1, $plainKey.Length - 2).Trim()
    }
    if ($plainKey -match '^(?i)Bearer\s+') {
        $plainKey = $plainKey -replace '^(?i)Bearer\s+', ''
    }
    if ($plainKey.Length -lt 10) {
        throw "The cleaned key was unexpectedly short. Nothing was saved."
    }
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    Remove-Variable secureKey -ErrorAction SilentlyContinue
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($secretPath, $plainKey, $utf8)

Remove-Variable plainKey -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "xAI access is configured in Signal Desk's local secrets folder." -ForegroundColor Green
Write-Host "The plaintext key was not written to the dashboard or source files."
Read-Host "Press Enter to close"
