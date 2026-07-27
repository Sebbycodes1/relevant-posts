function Get-XaiApiKey {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:XAI_API_KEY)) {
        return $env:XAI_API_KEY.Trim()
    }

    $localPath = Join-Path $ProjectRoot ".secrets\xai-api-key.local"
    if (Test-Path -LiteralPath $localPath) {
        $localKey = [IO.File]::ReadAllText($localPath).Trim()
        if ($localKey.Length -ge 10) { return $localKey }
    }

    $legacyPath = Join-Path $ProjectRoot ".secrets\xai-api-key.dpapi"
    if (Test-Path -LiteralPath $legacyPath) {
        try {
            $encryptedKey = [IO.File]::ReadAllText($legacyPath).Trim()
            $secureKey = ConvertTo-SecureString -String $encryptedKey
            $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
            try {
                $legacyKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer).Trim()
                if ($legacyKey.Length -ge 10) { return $legacyKey }
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
                Remove-Variable secureKey, encryptedKey -ErrorAction SilentlyContinue
            }
        }
        catch {
            throw "The legacy Windows-encrypted xAI key cannot be read in this sandbox. Open 'Configure xAI for Signal Desk' once to replace it."
        }
    }

    throw "No local xAI key is configured. Open 'Configure xAI for Signal Desk' first."
}
