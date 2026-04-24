# DMARC Dashboard on Azure

Fully serverless, event-driven DMARC aggregate report dashboard with Entra ID
authentication. Drop reports in a shared mailbox, Logic App saves attachments
to blob storage, Function rebuilds an HTML dashboard, another Function serves
it behind Easy Auth. Target cost: **< €0.10/month**.

## Architecture

```
  Shared mailbox (M365)
        │  new mail w/ attachment
        ▼
  Logic App (Consumption)           [system MI]
        │  save attachment
        ▼
  Storage ── raw/        (xml / gz / zip)
        │  blob trigger
        ▼
  ProcessDmarc Function             [system MI]
        │  parse + regenerate HTML
        ▼
  Storage ── dashboard/index.html   (private)
        ▲
        │  read on request
  Dashboard Function (HTTP)         [system MI]
        ▲
        │  authenticated request
  Easy Auth V2                       ── Entra ID tenant
        ▲
        │  https://<func>.azurewebsites.net/api/dashboard
        │
      Browser
```

One storage account, one Function App, two functions. All auth via managed
identities on the Azure side and Easy Auth V2 for browser access. Storage
has no public access; there's no `$web` static website container.

## Repository layout

```
infra/
  main.bicep                         # Storage, Function App, App Insights, Easy Auth, RBAC
function/
  host.json
  profile.ps1                        # Connect-AzAccount -Identity on cold start
  requirements.psd1                  # Az.Accounts + Az.Storage
  ProcessDmarc/
    function.json                    # Blob trigger on raw/{name}
    run.ps1                          # Parser + HTML generator
  Dashboard/
    function.json                    # HTTP trigger, route: /api/dashboard
    run.ps1                          # Reads blob + returns HTML
logicapp/
  SETUP.md                           # Portal click-ops guide for the mailbox trigger
docs/
  ENTRA-AUTH.md                      # Entra app registration + Easy Auth wiring
  GITHUB-SETUP.md                    # First-time GitHub + OIDC federated credential setup
.github/workflows/
  deploy.yml                         # Bicep + Function publish on push to main
.gitignore
```

## Deploy — two paths

You can deploy manually (az CLI) or via GitHub Actions. Recommended:
do a first manual deploy to shake things out, then set up GitHub for
everything after that.

### Path A: Manual (first-time or quick iterations)

**Stage 1 — infra without auth**

```powershell
$rg  = 'rg-dmarc'
$loc = 'westeurope'

az group create -n $rg -l $loc

$me = az ad signed-in-user show --query id -o tsv
az deployment group create -g $rg -f infra/main.bicep `
  -p namePrefix=dmarc adminPrincipalId=$me
```

Note the outputs: `functionAppName`, `functionAppHostname`, `dashboardUrl`.

**Stage 2 — function code**

```powershell
cd function
func azure functionapp publish <functionAppName> --powershell
cd ..
```

First cold start installs Az modules via managed dependencies (~2-3 min).

**Stage 3 — Logic App**

Follow [`logicapp/SETUP.md`](logicapp/SETUP.md). About 3 minutes of clicking.

**Stage 4 — Entra ID app registration + Easy Auth**

Follow [`docs/ENTRA-AUTH.md`](docs/ENTRA-AUTH.md). Creates the app reg,
sets the client secret, re-runs Bicep with `entraClientId` to flip auth on.

**Stage 5 — Test**

Email a DMARC report to the shared mailbox, wait ~1 minute, browse to the
`dashboardUrl`. You should hit an Entra login, sign in, and see your data.

### Path B: GitHub Actions (ongoing)

After the first manual deploy, follow [`docs/GITHUB-SETUP.md`](docs/GITHUB-SETUP.md)
to push this folder to a GitHub repo and wire up OIDC federated
credentials. From then on, `git push` deploys.

The workflow in `.github/workflows/deploy.yml`:
1. Logs into Azure via OIDC (no secrets)
2. Deploys `infra/main.bicep` with `entraClientId` from GitHub secrets
3. Publishes the function code with Functions Core Tools
4. Writes a summary with the dashboard URL

## Operations

### Cost monitoring

Set a €5/month budget on `rg-dmarc`. That's >50x your expected spend.

### Retention

Old raw XMLs accumulate. Add a lifecycle rule to delete blobs in `raw/`
older than 365 days. Reports are tiny so this is cosmetic, not cost-driven.

### Secret rotation

- **Easy Auth client secret** expires in 2 years (see `docs/ENTRA-AUTH.md`).
  Set a calendar reminder.
- **GitHub → Azure OIDC federated credential** never expires. No rotation
  needed.

### Switching to Event Grid blob trigger (lower latency)

Default blob trigger polls; upgrade to Event Grid for near-instant firing.
Not worth it for daily DMARC reports.

## Why this stack vs alternatives

- **App Service + Easy Auth**: B1 ≈ €13/mo for runtime you don't need.
- **Static Web Apps Standard with Entra**: clean, ~€9/mo, would require
  porting the parser to a Node/Python function since SWA Managed Functions
  don't support PowerShell.
- **Private endpoint + vWAN**: elegant but locks the dashboard to internal
  network only and costs ~€7/mo for the endpoint. Easy Auth works over
  plain internet with the same security guarantees for this use case.
- **Logic App Standard only**: can't parse gzipped XML cleanly without
  expensive inline code actions; worse, ~€150/mo baseline.

<!-- Deployed via GitHub Actions -->

<!-- Deployed via GitHub Actions -->
