#Requires -Version 7.0
param(
    [string]$UsagePath = '.\foundry-usage.csv',
    [string]$ScansPath = '.\scans.csv',
    [string]$PricesPath = '.\prices.csv',
    [string]$OutputPath = '.\repo-model-cost.csv'
)
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
function Read-Csv($path, $columns) {
    $rows = @(Import-Csv -LiteralPath $path)
    if (-not $rows.Count) { throw "Empty CSV: $path" }
    foreach ($column in $columns) {
        if ($column -notin $rows[0].PSObject.Properties.Name) { throw "Missing '$column' in $path." }
    }
    return $rows
}
function Read-Number([string]$text, [string]$label, [switch]$Whole) {
    $pattern = if ($Whole) { '^\d+$' } else { '^\d+(\.\d+)?$' }
    if ($text -notmatch $pattern) { throw "Invalid or missing $label ('$text'). Use nonnegative numbers with a decimal point." }
    return [decimal]::Parse($text, $culture)
}
function Read-Utc([string]$text) {
    if ($text -notmatch '(?i)T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$') {
        throw "Timestamp must include seconds and Z or a UTC offset: '$text'."
    }
    return ([DateTimeOffset]::Parse($text, $culture)).ToUniversalTime()
}
$usage = @(Read-Csv $UsagePath @('ResourceId', 'MinuteUtc', 'Deployment', 'InputTokens', 'OutputTokens'))
$scans = @(Read-Csv $ScansPath @('Repo', 'StartTime', 'EndTime'))
$prices = @(Read-Csv $PricesPath @('Deployment', 'Model', 'InputPerMillion', 'OutputPerMillion', 'Currency'))
if (@($usage.ResourceId | Select-Object -Unique).Count -ne 1 -or -not $usage[0].ResourceId.Trim()) {
    throw 'Use one Foundry account per report.'
}
$rates = @{}
foreach ($price in $prices) {
    if (-not $price.Deployment.Trim() -or -not $price.Model.Trim() -or -not $price.Currency.Trim() -or $rates.ContainsKey($price.Deployment)) {
        throw 'Prices must have unique, nonblank deployments and nonblank Model/Currency.'
    }
    $rates[$price.Deployment] = @{
        Model = $price.Model; Currency = $price.Currency
        Input = Read-Number $price.InputPerMillion 'InputPerMillion'
        Output = Read-Number $price.OutputPerMillion 'OutputPerMillion'
    }
}
if (@($prices.Currency | Select-Object -Unique).Count -ne 1) { throw 'Use a single currency per report.' }
$windows = @(
    foreach ($scan in $scans) {
        if (-not $scan.Repo.Trim() -or $scan.Repo -eq '(unattributed)') { throw 'Repo must be nonblank and not "(unattributed)".' }
        $start = Read-Utc $scan.StartTime
        $end = Read-Utc $scan.EndTime
        if ($end -le $start) { throw "EndTime must follow StartTime for '$($scan.Repo)'." }
        # Metrics are minute buckets: include every minute touched by the scan.
        $start = $start.AddTicks(-($start.Ticks % [TimeSpan]::TicksPerMinute))
        if ($end.Ticks % [TimeSpan]::TicksPerMinute) {
            $end = $end.AddTicks([TimeSpan]::TicksPerMinute - ($end.Ticks % [TimeSpan]::TicksPerMinute))
        }
        [pscustomobject]@{ Repo = $scan.Repo; Start = $start; End = $end }
    }
)
$windows = @($windows | Sort-Object Start)
for ($i = 1; $i -lt $windows.Count; $i++) {
    if ($windows[$i].Start -lt $windows[$i - 1].End) {
        throw 'Scan windows overlap after minute rounding. Shared deployment usage cannot be separated by repo.'
    }
}
$seen = @{}
$assigned = @(
    foreach ($row in $usage) {
        if (-not $rates.ContainsKey($row.Deployment)) { throw "Missing price for deployment '$($row.Deployment)'." }
        $minute = Read-Utc $row.MinuteUtc
        if ($minute.Ticks % [TimeSpan]::TicksPerMinute) { throw 'Usage timestamps must be minute-aligned.' }
        $key = "$($row.Deployment)|$($minute.Ticks)"
        if ($seen.ContainsKey($key)) { throw "Duplicate usage bucket: $key" }
        $seen[$key] = $true
        $match = @($windows | Where-Object { $minute -ge $_.Start -and $minute -lt $_.End })
        [pscustomobject]@{
            Repo = $(if ($match.Count) { $match[0].Repo } else { '(unattributed)' })
            Deployment = $row.Deployment
            InputTokens = Read-Number $row.InputTokens 'InputTokens' -Whole
            OutputTokens = Read-Number $row.OutputTokens 'OutputTokens' -Whole
        }
    }
)
foreach ($deployment in ($usage.Deployment | Select-Object -Unique)) {
    foreach ($window in $windows) {
        for ($minute = $window.Start; $minute -lt $window.End; $minute = $minute.AddMinutes(1)) {
            if (-not $seen.ContainsKey("$deployment|$($minute.Ticks)")) {
                throw "Missing usage bucket for '$deployment' at $minute. Export the entire scan period."
            }
        }
    }
}
$result = @(
    foreach ($group in ($assigned | Group-Object Repo, Deployment)) {
        $first = $group.Group[0]
        $rate = $rates[$first.Deployment]
        [decimal]$inputTotal = 0
        [decimal]$outputTotal = 0
        foreach ($row in $group.Group) { $inputTotal += $row.InputTokens; $outputTotal += $row.OutputTokens }
        $inputCost = $inputTotal * $rate.Input / 1000000
        $outputCost = $outputTotal * $rate.Output / 1000000
        [pscustomobject]@{
            Repo = $first.Repo; Deployment = $first.Deployment; Model = $rate.Model
            InputTokens = $inputTotal.ToString($culture); OutputTokens = $outputTotal.ToString($culture)
            TotalTokens = ($inputTotal + $outputTotal).ToString($culture)
            InputCost = $inputCost.ToString($culture); OutputCost = $outputCost.ToString($culture)
            EstimatedCost = ($inputCost + $outputCost).ToString($culture); Currency = $rate.Currency
            Attribution = $(if ($first.Repo -eq '(unattributed)') { 'Unattributed' } else { 'WindowEstimate' })
            PricingBasis = 'SuppliedTokenRates_NoCacheAdjustment'
        }
    }
)
$result | Sort-Object Repo, Deployment | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
$result | Sort-Object Repo, Deployment | Format-Table Repo, Model, InputTokens, OutputTokens, EstimatedCost, Currency, Attribution -AutoSize
Write-Warning 'Estimates include all traffic in rounded scan windows; cached-input discounts are not applied. Not PTU billing or an Azure invoice.'
Write-Host "Wrote $OutputPath"
