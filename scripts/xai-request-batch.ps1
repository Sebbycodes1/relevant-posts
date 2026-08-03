function Invoke-XaiResponseBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Requests,

        [Parameter(Mandatory = $true)]
        [string]$ApiKey,

        [ValidateRange(1, 4)]
        [int]$MaxConcurrency = 2,

        [ValidateRange(30, 900)]
        [int]$TimeoutSeconds = 420
    )

    if ($Requests.Count -eq 0) { return @() }

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $results = @()

    try {
        for ($offset = 0; $offset -lt $Requests.Count; $offset += $MaxConcurrency) {
            $lastIndex = [Math]::Min($offset + $MaxConcurrency - 1, $Requests.Count - 1)
            $chunk = @($Requests[$offset..$lastIndex])
            $pending = @()

            foreach ($request in $chunk) {
                $stage = [string]$request.Stage
                Assert-XaiBudgetAvailable $stage

                $bodyJson = if ($request.BodyJson) {
                    [string]$request.BodyJson
                }
                else {
                    $request.Body | ConvertTo-Json -Depth 30 -Compress
                }

                $message = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList @([System.Net.Http.HttpMethod]::Post, "https://api.x.ai/v1/responses")
                $null = $message.Headers.TryAddWithoutValidation("Authorization", "Bearer $ApiKey")
                $message.Content = New-Object -TypeName System.Net.Http.StringContent -ArgumentList @($bodyJson, [Text.Encoding]::UTF8, "application/json")
                $pending += [pscustomobject]@{
                    Key = [string]$request.Key
                    Stage = $stage
                    Message = $message
                    Task = $client.SendAsync($message)
                }
            }

            foreach ($item in $pending) {
                $httpResponse = $null
                try {
                    $httpResponse = $item.Task.GetAwaiter().GetResult()
                    $responseText = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if (-not $httpResponse.IsSuccessStatusCode) {
                        throw "xAI returned HTTP $([int]$httpResponse.StatusCode) for '$($item.Stage)'. $responseText"
                    }
                    try { $response = $responseText | ConvertFrom-Json }
                    catch { throw "xAI returned invalid response JSON for '$($item.Stage)'." }

                    Register-XaiResponseUsage $response $item.Stage
                    $results += [pscustomobject]@{
                        Key = $item.Key
                        Stage = $item.Stage
                        Response = $response
                    }
                }
                finally {
                    if ($httpResponse) { $httpResponse.Dispose() }
                    if ($item.Message) { $item.Message.Dispose() }
                }
            }
        }
    }
    finally {
        $client.Dispose()
    }

    return @($results)
}
