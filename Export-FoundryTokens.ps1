#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][DateTimeOffset]$StartTime,
    [Parameter(Mandatory)][DateTimeOffset]$EndTime,
    [string[]]$DeploymentName = @('gpt-5.4', 'gpt-5.4-mini', 'gpt-5.3-codex'),
    [string]$OutputPath = '.\foundry-usage.csv'
)
$ErrorActionPreference = 'Stop'
if ($ResourceId -notmatch '(?i)^/subscriptions/([^/\r\n\t]+)/resourceGroups/[^/\r\n\t]+/providers/Microsoft\.CognitiveServices/accounts/[^/\r\n\t]+\z') {
    throw 'Use the full Foundry account resource ID on one line.'
}
$subscription = $Matches[1]
$start = $StartTime.ToUniversalTime()
$end = $EndTime.ToUniversalTime()
if ($end -le $start -or ($end - $start).TotalDays -gt 7 -or
    $start.Ticks % [TimeSpan]::TicksPerMinute -or $end.Ticks % [TimeSpan]::TicksPerMinute) {
    throw 'Use increasing, complete-minute bounds covering at most seven days.'
}
if (-not $DeploymentName.Count -or @($DeploymentName | Where-Object { -not $_.Trim() }).Count) {
    throw 'Specify at least one nonblank deployment name.'
}
$startText = $start.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$endText = $end.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$rows = @(
    foreach ($deployment in ($DeploymentName | Select-Object -Unique)) {
        $json = az monitor metrics list --resource $ResourceId --subscription $subscription `
            --metrics ProcessedPromptTokens GeneratedTokens --aggregation Total --interval 1m `
            --start-time $startText --end-time $endText `
            --filter "ModelDeploymentName eq '$($deployment.Replace("'", "''"))'" `
            --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw "Azure metrics query failed for '$deployment'." }
        $response = ($json -join "`n") | ConvertFrom-Json -Depth 100
        if ($response.interval -ne 'PT1M') { throw 'Azure did not return minute buckets.' }
        $values = @{}
        foreach ($name in @('ProcessedPromptTokens', 'GeneratedTokens')) {
            $metric = @($response.value | Where-Object { $_.name.value -eq $name })
            if ($metric.Count -ne 1 -or ($metric[0].errorCode -and $metric[0].errorCode -ne 'Success') -or
                @($metric[0].timeseries).Count -ne 1) {
                throw "Missing, failed or ambiguous '$name' for '$deployment'."
            }
            $values[$name] = @{}
            foreach ($point in $metric[0].timeseries[0].data) {
                $stamp = ([DateTimeOffset]$point.timeStamp).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
                if ($values[$name].ContainsKey($stamp)) { throw "Duplicate metric bucket: $deployment / $name / $stamp." }
                $values[$name][$stamp] = $point.total
            }
        }
        for ($minute = $start; $minute -lt $end; $minute = $minute.AddMinutes(1)) {
            $stamp = $minute.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
            [pscustomobject]@{
                ResourceId = $ResourceId; MinuteUtc = $stamp; Deployment = $deployment
                InputTokens = $values['ProcessedPromptTokens'][$stamp]
                OutputTokens = $values['GeneratedTokens'][$stamp]
            }
        }
    }
)
if (-not @($rows | Where-Object { $null -ne $_.InputTokens -or $null -ne $_.OutputTokens }).Count) {
    throw 'No observed tokens returned. Check deployment names, time window and metric delay.'
}
$rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
Write-Warning 'Export includes all deployment traffic. Blank token values are unknown, not zero; retry after metric ingestion if needed.'
Write-Host "Wrote $($rows.Count) minute/deployment rows to $OutputPath"
