# scan-token-cost

Measure Azure Foundry token usage by model and minute for agentic code scans, then use it to:

1. **Estimate cost per scan/repo**, by model.
2. **Collect data for a rough PTU estimate.**

Requires PowerShell 7 and Azure CLI (`az login`) with read access to the Foundry resource's metrics. These scripts do not call models and do not read Defender scan reports.

## 1. Export Foundry usage (both goals)

```powershell
$resourceId = '/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<foundry-account>'

.\Export-FoundryTokens.ps1 -ResourceId $resourceId `
    -StartTime '2026-10-16T14:44:00Z' -EndTime '2026-10-16T15:24:00Z' `
    -DeploymentName 'gpt-5.4','gpt-5.4-mini','gpt-5.3-codex'
```

- Use UTC, whole-minute bounds covering all scans (up to 7 days). End is exclusive.
- Writes `foundry-usage.csv`: `ResourceId,MinuteUtc,Deployment,InputTokens,OutputTokens`.
- Blank tokens mean unknown, not zero. If metrics are still arriving, rerun later.
- The export includes all traffic on those deployments and your resource ID.

See [`examples/foundry-usage.csv`](examples/foundry-usage.csv) for a real, anonymized export.

## 2. Estimate cost per scan

Get each scan's job and timing from Defender:

```powershell
.\defender status              # list tracked scan jobs
.\defender status <JOB_ID>     # details for one job
```

Create `scans.csv` with each repo's actual scan start and end times (UTC). Use the job details above; if your CLI version doesn't show times, use the Scans tab in the Defender portal or note them when you run the scan.

```csv
Repo,StartTime,EndTime
repo-a,2026-10-16T14:44:00Z,2026-10-16T15:00:00Z
repo-b,2026-10-16T15:00:00Z,2026-10-16T15:24:00Z
```

Then get current public prices and join:

```powershell
.\Get-FoundryPrices.ps1 -Region eastus2 -Currency USD
.\Join-ScanTokenCost.ps1
```

`Get-FoundryPrices.ps1` writes `prices.csv` (Global Standard input/output rates for `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`). For deployment aliases, pass `-DeploymentModels @{ 'my-alias' = 'gpt-5.4' }`. For negotiated or other rates, edit `prices.csv` (`Deployment,Model,InputPerMillion,OutputPerMillion,Currency`).

The output, `repo-model-cost.csv`, has tokens and estimated cost per repo and model. Usage outside the scan windows is reported as `(unattributed)`.

**Cross-check:** the Defender portal (Exposure management > Initiatives > Codename MDASH > Manage scans) shows **tokens consumed in the last scan** per repo. Record it after each scan and compare it with the report's token total. Only the latest scan per repo is shown, so capture it before rescanning.

**Use only for scans run one at a time**, with no other traffic on the deployments. Foundry metrics do not identify repos, so cost is a time-window estimate. Overlapping scan windows are rejected.

## 3. Collect data for a PTU estimate

Run representative scans at the **expected concurrency**, export usage as in step 1, and send us:

- `foundry-usage.csv` (skip the cost join, so concurrent scans are fine)
- Scan start/end times (from `defender status`), the scan configuration (`standard` or `mai-cyber`), and the concurrency used
- The portal's "tokens consumed in the last scan" for each repo, if available
- For each deployment: model and version, deployment type, region, and TPM quota
- Expected scans per hour and target scan duration
- Any 429s, timeouts, or queueing during the test

Minute totals give average and peak load per model, a starting point for PTU sizing rather than a capacity guarantee. Share through an approved channel. Do not send keys, tokens, source code, or scan findings.

## Limits

- Estimates use public token prices: no cached-input discounts, negotiated rates, or PTU billing, and not an invoice.
- Input tokens include cached tokens; output tokens already include reasoning.
- If a deployment's model or price changes during the period, run separate reports.
- The `mai-cyber` scan configuration adds a fourth model (MAI-Cyber-1-Flash). Add its deployment to the export and its rates to `prices.csv` (`Get-FoundryPrices.ps1` only covers the three standard models).
