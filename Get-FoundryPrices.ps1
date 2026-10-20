#Requires -Version 7.0
<#
Fetch current public Global Standard token prices for the three MDASH models.
No Azure login needed. Does not retrieve negotiated, Batch, PTU or cached-input rates.
#>
param(
    [ValidatePattern('^[a-z0-9]+$')][string]$Region = 'eastus2',
    [ValidatePattern('^[A-Za-z]{3}$')][string]$Currency = 'USD',
    [hashtable]$DeploymentModels = @{
        'gpt-5.4' = 'gpt-5.4'
        'gpt-5.4-mini' = 'gpt-5.4-mini'
        'gpt-5.3-codex' = 'gpt-5.3-codex'
    },
    [string]$OutputPath = '.\prices.csv'
)
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
$Currency = $Currency.ToUpperInvariant()
# Exact catalog SKUs exclude cached, priority-processing, Batch and data-zone meters.
$modelSkus = @{
    'gpt-5.4' = '5.4'
    'gpt-5.4-mini' = '5.4 mini'
    'gpt-5.3-codex' = '5.3 codex'
}
if (-not $DeploymentModels.Count) { throw 'Specify at least one deployment/model mapping.' }
foreach ($deployment in $DeploymentModels.Keys) {
    if (-not "$deployment".Trim() -or -not $modelSkus.ContainsKey($DeploymentModels[$deployment])) {
        throw "Unsupported mapping '$deployment'. Supported models: $($modelSkus.Keys -join ', ')."
    }
}
$filter = "serviceName eq 'Foundry Models' and productName eq 'Azure OpenAI GPT5' and armRegionName eq '$Region' and priceType eq 'Consumption'"
$url = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='$Currency'&`$filter=" +
    [uri]::EscapeDataString($filter)
$items = @(
    do {
        $page = Invoke-RestMethod -Uri $url -TimeoutSec 60
        if ($null -eq $page.Items) { throw 'Azure Retail Prices API returned no Items collection.' }
        $page.Items
        $url = $page.NextPageLink
        if ($url -and ([uri]$url).GetLeftPart([UriPartial]::Authority) -ne 'https://prices.azure.com') {
            throw 'Unexpected pricing pagination host.'
        }
    } while ($url)
)
$rows = @(
    foreach ($deployment in ($DeploymentModels.Keys | Sort-Object)) {
        $model = $DeploymentModels[$deployment]
        $rates = @{}
        foreach ($direction in @('inp', 'opt')) {
            $sku = "$($modelSkus[$model]) $direction Gl"
            $match = @($items | Where-Object {
                $_.skuName -eq $sku -and $_.meterName -eq "$sku 1M Tokens" -and
                $_.productName -eq 'Azure OpenAI GPT5' -and $_.serviceName -eq 'Foundry Models' -and
                $_.armRegionName -eq $Region -and $_.currencyCode -eq $Currency -and
                $_.type -eq 'Consumption' -and $null -ne $_.tierMinimumUnits -and $_.tierMinimumUnits -eq 0 -and
                $_.isPrimaryMeterRegion -eq $true -and $_.effectiveStartDate -and
                [DateTimeOffset]$_.effectiveStartDate -le [DateTimeOffset]::UtcNow
            })
            if ($match.Count -ne 1) {
                throw "Expected one current '$sku' retail meter in '$Region'; found $($match.Count). No prices written. Check catalog availability; do not substitute another deployment type."
            }
            if ($match[0].unitOfMeasure -ne '1M' -or $null -eq $match[0].retailPrice -or $match[0].retailPrice -lt 0) {
                throw "Unexpected price or unit for '$sku'. Expected a nonnegative price per 1M tokens."
            }
            $rates[$direction] = ([decimal]$match[0].retailPrice).ToString($culture)
        }
        [pscustomobject]@{
            Deployment = $deployment; Model = $model
            InputPerMillion = $rates.inp; OutputPerMillion = $rates.opt; Currency = $Currency
        }
    }
)
$rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
$rows | Format-Table -AutoSize
Write-Host "Wrote $OutputPath (current public Global Standard retail prices, region $Region)."
Write-Warning 'Not negotiated or historical prices. Cached-input discounts are not applied by the join. Do not use for PTU, Batch, priority processing, data-zone or regional deployments.'
