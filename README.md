# scan-token-cost

Simple PowerShell scripts that turn Azure Foundry token metrics into answers for MDASH agentic code scans.

Requires PowerShell 7 and Azure CLI (`az login`) with read access to the Foundry resource's metrics. The scripts do not call models.

## Part 1: Is the Foundry export enough to size PTUs?

Yes, if the Foundry resource is used only for MDASH. Every token on the deployments is then scan traffic, so the export alone shows load by model and minute.

```powershell
$resourceId = '/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<foundry-account>'

.\Export-FoundryTokens.ps1 -ResourceId $resourceId `
    -StartTime '2026-10-16T14:44:00Z' -EndTime '2026-10-16T15:24:00Z' `
    -DeploymentName 'gpt-5.4','gpt-5.4-mini','gpt-5.3-codex'
```

- Use UTC, whole-minute bounds (up to 7 days). End is exclusive.
- Writes `foundry-usage.csv`: `ResourceId,MinuteUtc,Deployment,InputTokens,OutputTokens`. Blank tokens mean unknown, not zero.
- The file includes your resource ID. [`examples/foundry-usage.csv`](examples/foundry-usage.csv) is an anonymized sample.

Run it over a period of representative scans, at the concurrency you expect in production. Per model, peak and average input and output tokens per minute are the starting point for PTU sizing. Also note each deployment's model, region and TPM quota, and any 429s during the test. Send the CSV through an approved channel (no keys, source code or findings).

This is a sizing starting point, not a capacity guarantee.

## Part 2: Cost per repo (optional)

If you can export from the Defender CLI the repo, tokens, start time and end time for each scan, you can also see cost by model by repo.

1. Get scan jobs from the CLI (`.\defender status`, `.\defender status <JOB_ID>`) and create `scans.csv` with each repo's start and end time in UTC:

```csv
Repo,StartTime,EndTime
repo-a,2026-10-16T14:44:00Z,2026-10-16T15:00:00Z
repo-b,2026-10-16T15:00:00Z,2026-10-16T15:24:00Z
```

2. Get prices and join:

```powershell
.\Get-FoundryPrices.ps1 -Region eastus2 -Currency USD
.\Join-ScanTokenCost.ps1
```

`Get-FoundryPrices.ps1` writes `prices.csv` (public Global Standard rates). Edit it for negotiated rates or deployment aliases. The output, `repo-model-cost.csv`, has tokens and estimated cost per repo and model. Usage outside the scan windows is `(unattributed)`.

The per-repo tokens you export from Defender can be compared with the report's token totals as a sanity check.

**Limits**
- Run scans one at a time with no other traffic: Foundry metrics don't identify repos, so cost is a time-window estimate. Overlapping windows are rejected.
- Public token prices only: no cached-input discount, negotiated rates or PTU billing. Not an invoice.
- The `mai-cyber` configuration adds a fourth model. Add its deployment to the export and its rates to `prices.csv`.
