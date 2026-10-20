# Simple repo/model token and cost report

Two preparation steps, then one combine command. PowerShell 7 and Azure CLI are
required for the Foundry export. The join runs offline. No HTML, packages or inference calls.
Open PowerShell in this folder to run the commands below. One Foundry export
covers all scans; there is no per-repo Azure query loop.

## What about SARIF?

SARIF (Static Analysis Results Interchange Format) is a known, JSON-based standard
for security findings. MDASH documents SARIF 2.1.0 output: `runs[].results[]`
contains findings, `runs[].tool` describes the scanner, and locations/code flows
describe affected code and execution paths.

SARIF allows extensions, but the public MDASH documentation does **not** document
a per-repo/model token ledger. This example therefore does not parse SARIF or claim
to export measured MDASH token counts. Its second input is a simple scan manifest
you create from the actual scan execution times.

Sources:
- [Microsoft: review MDASH terminal results](https://learn.microsoft.com/en-us/security-exposure-management/review-terminal-results)
- [Microsoft: MDASH FAQ](https://learn.microsoft.com/en-us/security-exposure-management/codename-mdash-faq)
- [Microsoft: Azure OpenAI monitoring reference](https://learn.microsoft.com/en-us/azure/foundry/openai/monitor-openai-reference)

## 1. Export Foundry usage once

Sign in with permission to read the Foundry resource and its metrics:

```powershell
az login
$resourceId = '/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<foundry-account>'

.\Export-FoundryTokens.ps1 -ResourceId $resourceId `
    -StartTime '2026-10-16T14:44:00Z' -EndTime '2026-10-16T15:24:00Z' `
    -DeploymentName 'gpt-5.4','gpt-5.4-mini','gpt-5.3-codex'
```

Replace the account, deployments and UTC bounds for the customer. Use full minute
boundaries enclosing every scan; end is exclusive. One invocation covers multiple
repos, up to seven days. Default output: `foundry-usage.csv`.

Columns: `ResourceId,MinuteUtc,Deployment,InputTokens,OutputTokens`.
The token metrics are summed per minute, not averaged. Blank values are unknown,
not zero. Allow metric ingestion to finish and rerun if necessary; the join refuses
missing values instead of understating totals.

### Included real-data example

[`examples/foundry-usage.csv`](examples/foundry-usage.csv) contains a live Azure
metrics export for a synthetic scan workload on October 16, 2026,
14:44-15:24 UTC: 40 minutes per deployment, 120 rows, no unknown buckets.
Azure subscription/resource identifiers have been replaced with placeholders;
timestamps and token counts are unchanged.

| Deployment | Input tokens | Output tokens |
| --- | ---: | ---: |
| gpt-5.4 | 444,055 | 147,400 |
| gpt-5.4-mini | 436,986 | 40,624 |
| gpt-5.3-codex | 508,259 | 56,910 |

This is a data-format example, not a production benchmark or PTU recommendation.
The synthetic scans ran concurrently: do not use these totals as exact per-repo
attribution or run the cost join against invented repo windows. For customer data,
run the command above with the customer's resource and actual scan period.

## Share data for a rough PTU estimate

1. Run representative repo scans, including the **expected concurrent scan load**.
   Record scan start/end times, failures, throttling and any unrelated model traffic.
2. After metrics have arrived, run the export command in step 1 with UTC bounds
   enclosing the complete test and all model deployments used. Keep **minute-level**
   data; do not replace it with hourly totals.
3. Send us:
   - `foundry-usage.csv` and `scans.csv` (repo labels may be anonymized).
   - Each deployment's **actual model name/version, deployment type, region and
     configured TPM quota**; deployment aliases alone do not identify the model.
   - Test concurrency, expected scans/hour and target scan completion time.
     Note any 429s, timeouts, queueing or quota limits that may have capped demand.
4. We will review average/peak input and output TPM per model and use current
   [Microsoft PTU sizing guidance](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/provisioned-throughput-sizing)
   to form a rough estimate, then validate with a representative load test.

**For PTU sizing, concurrent scans are useful:** send the raw export without
running the cost join, which rejects overlapping scan windows. Prices and SARIF
findings are not required. These totals do not capture request-size distributions,
cache hits or sub-minute bursts, so they are a starting point, not a capacity
guarantee. Share through an approved channel; the CSV contains Azure resource IDs.
Do not send API keys, access tokens, source code or scan findings.

## 2. Create the repo scan list

Save this shape as `scans.csv`, replacing the illustrative names and timestamps
with **actual** scan execution start/end times (not submission or download times):

```csv
Repo,StartTime,EndTime
repo-a,2026-10-16T14:44:00Z,2026-10-16T15:00:00Z
repo-b,2026-10-16T15:00:00Z,2026-10-16T15:24:00Z
```

These rows illustrate the format; they are not real repo attribution for the
earlier synthetic test. Include every scan you intend to account for. Repeated repo
names are allowed for separate scans and are summed in the report.

Seconds are allowed and require `Z` or an explicit offset. The join rounds start
down and end up to whole minutes. If rounded windows overlap, it stops: even
sequential scans sharing a minute cannot be separated exactly.

**Only use this method when scans run separately and there is no other traffic
on those deployments.** Unknown concurrent scans or unrelated traffic cannot be
detected from the manifest. A scan's window must cover its model calls; submission,
queueing and processing times may differ. Boundary rounding introduces an estimate.
Each scan is assumed to use the selected account/deployments; use a separate
report for another account or deployment set.

## Combine and price

Fetch `prices.csv` from the public Azure Retail Prices API (no login needed):

```powershell
.\Get-FoundryPrices.ps1 -Region 'eastus2' -Currency 'USD'
.\Join-ScanTokenCost.ps1
```

This fetches **current public Global Standard** input/output rates for the three
MDASH models, writes `prices.csv`, and prints the selected prices. Exact meter
matching excludes cached input, Batch, priority processing and data-zone prices.
The script follows pagination and stops if a price is missing or ambiguous.
It does not discover your deployment type or model automatically.

For deployment aliases, supply their model mapping:

```powershell
.\Get-FoundryPrices.ps1 -DeploymentModels @{
    'review-deployment' = 'gpt-5.4'
    'inventory-deployment' = 'gpt-5.4-mini'
    'validation-deployment' = 'gpt-5.3-codex'
}
```

Only those three models are supported by this small helper. It does not retrieve
your negotiated rates, historical rates, PTU costs or other deployment-type rates.
For those token-rate cases, create/edit `prices.csv` manually with applicable rates.
Non-USD API rates are reference estimates. Public API documentation:
[Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices).

The generated CSV has these columns (blank rates below illustrate the shape only):

```csv
Deployment,Model,InputPerMillion,OutputPerMillion,Currency
gpt-5.4,gpt-5.4,,,USD
gpt-5.4-mini,gpt-5.4-mini,,,USD
gpt-5.3-codex,gpt-5.3-codex,,,USD
```

**If creating the CSV manually, fill the blank rates before running.** Use your applicable
model/version, deployment type, region, date and currency/contract token rates per
one million tokens. Deployment names can be aliases: the `Model` column is your
explicit deployment-to-model mapping for that period. Use one currency, with
decimal points and no currency symbols or thousands separators. If a deployment
changes model or price during the period, split the report at that boundary.

```powershell
.\Join-ScanTokenCost.ps1
```

Defaults read `foundry-usage.csv`, `scans.csv`, `prices.csv` and write
`repo-model-cost.csv`, plus a short terminal table. To use different filenames:

```powershell
.\Join-ScanTokenCost.ps1 -UsagePath '.\foundry-usage.csv' `
    -ScansPath '.\scans.csv' -PricesPath '.\prices.csv' `
    -OutputPath '.\repo-model-cost.csv'
```

Each output row is a repo/deployment/model subtotal across its scans:
input, output and total tokens; input/output cost; estimated combined cost;
currency; attribution and pricing basis.

```text
EstimatedCost = InputTokens / 1,000,000 * InputPerMillion
              + OutputTokens / 1,000,000 * OutputPerMillion
```

Usage outside the supplied scan windows is retained under `(unattributed)`, so
the report reconciles to the exported tokens rather than silently dropping them.
Sum `EstimatedCost` by repo for repo totals, or by `Repo,Model` if multiple
deployments use the same model.

### What this report does not prove

- `WindowEstimate` means all deployment tokens inside that scan's rounded window;
  it is **not** request-level MDASH attribution.
- Input tokens include cached input. This simple version does not split cached
  tokens or apply their discounts; using standard uncached input rates can
  overestimate token cost. Output includes reasoning; do not add it again.
- It calculates a token-rate estimate, not PTU capacity/reservation cost, the Azure
  invoice, taxes, or other services. Do not apply these token rates to PTU billing.
- Overlapping scans are deliberately rejected, not allocated by duration.
- With only repo/start/end, exact concurrent per-repo costs are not recoverable.
