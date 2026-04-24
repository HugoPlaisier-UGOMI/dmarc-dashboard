# DMARC Dashboard on Azure

Serverless DMARC aggregate report dashboard with Entra ID authentication.
Reports flow in via a shared mailbox, get parsed automatically, and are
visualized in a self-updating HTML dashboard — all for under €2.50/month.

![Dashboard preview](docs/images/dashboard-preview.png)

## What it does

- **Ingests** DMARC aggregate reports (XML, ZIP, GZ) from a shared M365 mailbox via Logic App
- **Parses** reports per RFC 7489: DMARC compliance = aligned DKIM pass OR aligned SPF pass
- **Visualizes** compliance in an HTML dashboard with:
  - Summary cards (total, compliant, failed, rate, Azure cost)
  - Last 7 days bar chart (stacked: compliant + non-compliant)
  - Domain overview with pie charts (message distribution + per-domain compliance)
  - Last 12 months bar chart
  - Source IP table with reverse DNS hostnames (scrollable)
  - Compliance by Header-From domain
  - Per-domain detail cards: DMARC compliance, SPF alignment, DKIM alignment percentages with progress bars
  - Live SPF and DMARC DNS record display per domain
  - Reporting organisations overview
  - Top 100 non-compliant rows with full detail
- **Authenticates** via Entra ID Easy Auth — only assigned users can access
- **Archives** processed reports to `archive/YYYY/` folders automatically
- **Deploys** via GitHub Actions with OIDC federated credentials (no secrets)

## Architecture

```
  Shared mailbox (M365)
        │  new mail (polled every 15 min)
        ▼
  Logic App (Consumption)           [system MI]
        │  base64ToBinary → save attachment
        ▼
  Storage Account ── raw/           (xml / gz / zip landing zone)
        │
        │  timer trigger (every 4 hours)
        ▼
  ProcessDmarc Function             [system MI]
        │  parse all blobs (raw + archive)
        │  reverse DNS, DNS record lookups
        │  Azure Cost Management query
        │  generate HTML dashboard
        │  archive processed blobs to archive/YYYY/
        ▼
  Storage Account ── dashboard/index.html (private)
        ▲
        │  HTTP request
  Dashboard Function (HTTP)         [system MI]
        ▲
        │  Entra ID login
  Easy Auth V2
        ▲
  Browser ── https://<func>.azurewebsites.net/api/dashboard
```

One storage account, one Function App (Windows Consumption, PowerShell 7.4,
64-bit), two functions, one Logic App. All data access via managed identity.
Storage has no public access.

## Repository layout

```
infra/
  main.bicep                         # Storage, Function App, App Insights, Easy Auth, RBAC
function/
  host.json                          # Functions runtime config, managed dependencies
  profile.ps1                        # Connect-AzAccount -Identity on cold start
  requirements.psd1                  # Az.Accounts + Az.Storage
  ProcessDmarc/
    function.json                    # Timer trigger (every 4 hours)
    run.ps1                          # Parser, charts, DNS lookups, cost query, HTML generator
  Dashboard/
    function.json                    # HTTP trigger, route: /api/dashboard
    run.ps1                          # Reads dashboard blob, serves HTML with Easy Auth identity
logicapp/
  SETUP.md                           # Portal setup guide for the mailbox trigger
docs/
  ENTRA-AUTH.md                      # Entra app registration + Easy Auth setup
  GITHUB-SETUP.md                    # First-time GitHub + OIDC federated credential setup
  images/                            # Dashboard screenshot(s)
.github/workflows/
  deploy.yml                         # Bicep + Function publish on push to main (OIDC auth)
```

## Prerequisites

- Azure subscription with Owner or Contributor + User Access Administrator on a resource group
- M365 shared mailbox for receiving DMARC reports
- GitHub account (for CI/CD)
- Local tools: Azure CLI, Azure Functions Core Tools v4, Git, GitHub CLI

## Deploy

### 1. Infrastructure (Bicep)

```powershell
az group create -n rg-dmarc -l westeurope

$me = az ad signed-in-user show --query id -o tsv
az deployment group create -g rg-dmarc -f infra/main.bicep `
  -p namePrefix=dmarc adminPrincipalId=$me
```

### 2. Function code

```powershell
cd function
func azure functionapp publish <functionAppName> --powershell
```

First cold start takes 2-3 minutes (managed dependency install for Az modules).

### 3. Logic App

Follow [logicapp/SETUP.md](logicapp/SETUP.md). Key detail: use
`base64ToBinary(items('For_each')?['ContentBytes'])` as the blob content
expression — without this, attachments are stored as base64 text instead of binary.

### 4. Entra ID authentication

Follow [docs/ENTRA-AUTH.md](docs/ENTRA-AUTH.md) to create an app registration
and enable Easy Auth on the Function App.

### 5. GitHub Actions (optional)

Follow [docs/GITHUB-SETUP.md](docs/GITHUB-SETUP.md) for OIDC federated
credentials and automatic deploys on `git push`.

## Cost

Typical monthly cost: **€1.50 – €2.50**

| Component | Cost driver | Typical |
|---|---|---|
| Storage | File share (Function content) + blob transactions | ~€0.80 |
| Logic App | Trigger polls (every 15 min) + actions per email | ~€0.60 |
| Function App | Consumption plan, 6 runs/day × ~30s each | ~€0.00 |
| App Insights | Telemetry ingestion (first 5 GB free) | ~€0.00 |

The dashboard shows live Azure costs for the resource group via the Cost
Management API. Requires `Cost Management Reader` role on the Function App MI.

## Colorblind accessibility

The dashboard uses a colorblind-safe palette throughout:
- Compliant: teal-green (`#0a7d4f`)
- Non-compliant: Wong blue (`#0072B2`)
- No red/green distinction anywhere

## Key design decisions

- **Timer trigger instead of blob trigger**: blob triggers on Windows
  Consumption go to sleep after idle periods. A 4-hourly timer is reliable
  and keeps the host warm enough to respond quickly.
- **Connection string for AzureWebJobsStorage**: identity-based
  AzureWebJobsStorage caused deployment issues on Windows Consumption.
  The connection string is used only for Functions runtime state; actual
  data access (raw, dashboard, archive blobs) uses managed identity.
- **Full re-scan on every run**: ProcessDmarc reads all blobs from both
  `raw/` and `archive/` on every trigger. At typical DMARC volumes (a few
  reports/day, KB-sized) this is trivial. For very high volumes, consider
  switching to a database for parsed records.
- **DNS lookups via Google DNS-over-HTTPS**: `Resolve-DnsName` is not
  available on Azure Functions' sandboxed Windows environment. Google's
  public DNS JSON API (`dns.google/resolve`) works everywhere.

## License

MIT
