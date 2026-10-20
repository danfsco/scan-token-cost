# scan-token-cost

PowerShell scripts that turn Azure Foundry token metrics into usage and cost data for MDASH agentic code scans.

**Requirements:** PowerShell 7 and Azure CLI (`az login`) with read access to the Foundry resource's metrics. The scripts do not call models.

## Part 1: Token usage by model for PTU sizing

Exports input and output tokens per model per minute from your Foundry resource. If the resource is used only for MDASH, all of this traffic is scan traffic.

```powershell
$resourceId = '/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<foundry-account>'

.\Export-FoundryTokens.ps1 -ResourceId $resourceId `
    -StartTime '2026-10-16T14:44:00Z' -EndTime '2026-10-16T15:24:00Z' `
    -DeploymentName 'gpt-5.4','gpt-5.4-mini','gpt-5.3-codex'
```

- Use UTC, whole-minute bounds (up to 7 days). End is exclusive.
- Output `foundry-usage.csv` has `ResourceId,MinuteUtc,Deployment,InputTokens,OutputTokens`. Blank tokens mean unknown, not zero.
- The file contains your resource ID. See [`examples/foundry-usage.csv`](examples/foundry-usage.csv) for an anonymized sample.

**For a PTU estimate:** export a period of representative scans at your expected concurrency. Peak and average tokens per minute per model are the starting point for sizing. Also record each deployment's model, region and TPM quota, and any 429 errors. This is a sizing input, not a capacity guarantee.

## Part 2: Cost per repo (optional)

If you can export the repo, start time and end time of each scan from the Defender CLI, you can estimate cost by model by repo.

1. Create `scans.csv` with each scan's repo and UTC start and end time (`.\defender status` lists jobs):

```csv
Repo,StartTime,EndTime
repo-a,2026-10-16T14:44:00Z,2026-10-16T15:00:00Z
repo-b,2026-10-16T15:00:00Z,2026-10-16T15:24:00Z
```

2. Get prices and run the join:

```powershell
.\Get-FoundryPrices.ps1 -Region eastus2 -Currency USD
.\Join-ScanTokenCost.ps1
```

`Get-FoundryPrices.ps1` writes `prices.csv` with public Global Standard rates; edit it for negotiated rates or deployment aliases. `repo-model-cost.csv` has tokens and estimated cost per repo and model. Usage outside the scan windows appears as `(unattributed)`.

### Limits

- Foundry metrics don't identify repos, so cost is a time-window estimate. Run scans one at a time with no other traffic on the deployments; overlapping windows are rejected.
- Costs use public token prices: no cached-input discount, negotiated rates or PTU billing. This is not an invoice.
- The `mai-cyber` scan configuration adds a fourth model. Add its deployment to the export and its rates to `prices.csv`.
