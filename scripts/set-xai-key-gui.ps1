$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $PSScriptRoot
$secretDirectory = Join-Path $projectRoot ".secrets"
$secretPath = Join-Path $secretDirectory "xai-api-key.local"

$form = New-Object System.Windows.Forms.Form
$form.Text = "Configure xAI for Signal Desk"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(560, 255)
$form.MinimumSize = New-Object System.Drawing.Size(560, 255)
$form.MaximizeBox = $false
$form.FormBorderStyle = "FixedDialog"
$form.TopMost = $true

$title = New-Object System.Windows.Forms.Label
$title.Text = "Connect your xAI API key"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.AutoSize = $true
$form.Controls.Add($title)

$help = New-Object System.Windows.Forms.Label
$help.Text = "Copy the active key from console.x.ai, then select Paste from clipboard. The key stays in this device's Git-ignored secrets folder and is never added to the dashboard or chat."
$help.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$help.ForeColor = [System.Drawing.Color]::FromArgb(75, 82, 78)
$help.Location = New-Object System.Drawing.Point(24, 55)
$help.Size = New-Object System.Drawing.Size(505, 42)
$form.Controls.Add($help)

$keyBox = New-Object System.Windows.Forms.TextBox
$keyBox.Location = New-Object System.Drawing.Point(25, 102)
$keyBox.Size = New-Object System.Drawing.Size(355, 27)
$keyBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$keyBox.UseSystemPasswordChar = $true
$keyBox.TabIndex = 0
$form.Controls.Add($keyBox)

$pasteButton = New-Object System.Windows.Forms.Button
$pasteButton.Text = "Paste from clipboard"
$pasteButton.Location = New-Object System.Drawing.Point(390, 100)
$pasteButton.Size = New-Object System.Drawing.Size(140, 30)
$pasteButton.TabIndex = 1
$pasteButton.Add_Click({
    try {
        $clipboardText = [System.Windows.Forms.Clipboard]::GetText()
        if ([string]::IsNullOrWhiteSpace($clipboardText)) {
            [System.Windows.Forms.MessageBox]::Show("The clipboard does not contain text. Copy the key from the xAI Console first.", "Nothing to paste", "OK", "Information") | Out-Null
            return
        }
        $keyBox.Text = $clipboardText.Trim()
        $keyBox.Focus()
        $keyBox.SelectionStart = $keyBox.Text.Length
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Windows could not read the clipboard. You can still type the key into the masked box.", "Clipboard unavailable", "OK", "Warning") | Out-Null
    }
})
$form.Controls.Add($pasteButton)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Enter the raw key only - without quotes or the word Bearer."
$status.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$status.ForeColor = [System.Drawing.Color]::FromArgb(110, 90, 45)
$status.Location = New-Object System.Drawing.Point(25, 136)
$status.Size = New-Object System.Drawing.Size(500, 24)
$form.Controls.Add($status)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Location = New-Object System.Drawing.Point(352, 169)
$cancelButton.Size = New-Object System.Drawing.Size(82, 31)
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $cancelButton
$form.Controls.Add($cancelButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save locally"
$saveButton.Location = New-Object System.Drawing.Point(442, 169)
$saveButton.Size = New-Object System.Drawing.Size(88, 31)
$saveButton.TabIndex = 2
$saveButton.Add_Click({
    $candidate = $keyBox.Text.Trim()
    if (($candidate.StartsWith('"') -and $candidate.EndsWith('"')) -or ($candidate.StartsWith("'") -and $candidate.EndsWith("'"))) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2).Trim()
    }
    $candidate = $candidate -replace '^(?i)Bearer\s+', ''
    if ($candidate.Length -lt 10) {
        [System.Windows.Forms.MessageBox]::Show("The value is empty or unexpectedly short. Copy the complete active API key and try again.", "Key not saved", "OK", "Warning") | Out-Null
        return
    }
    $status.Text = "Checking the key with xAI..."
    $status.ForeColor = [System.Drawing.Color]::FromArgb(23, 75, 58)
    $saveButton.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Invoke-RestMethod -Method Get -Uri "https://api.x.ai/v1/models" -Headers @{ Authorization = "Bearer $candidate" } -TimeoutSec 20 | Out-Null
    }
    catch {
        $status.Text = "xAI did not accept this key."
        $status.ForeColor = [System.Drawing.Color]::FromArgb(160, 62, 48)
        $saveButton.Enabled = $true
        [System.Windows.Forms.MessageBox]::Show("xAI rejected this value. Copy a currently active API key directly from console.x.ai and try again.", "Key not saved", "OK", "Warning") | Out-Null
        return
    }
    $form.Tag = $candidate
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})
$form.AcceptButton = $saveButton
$form.Controls.Add($saveButton)

$result = $form.ShowDialog()
if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    exit 0
}

$plainKey = [string]$form.Tag
try {
    New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($secretPath, $plainKey, $utf8)
    try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
}
finally {
    $keyBox.Clear()
    $form.Tag = $null
    Remove-Variable plainKey -ErrorAction SilentlyContinue
}

[System.Windows.Forms.MessageBox]::Show(
    "The xAI API key was saved in Signal Desk's local Git-ignored secrets folder. You can now refresh the dashboard.",
    "Signal Desk configured",
    "OK",
    "Information"
) | Out-Null
