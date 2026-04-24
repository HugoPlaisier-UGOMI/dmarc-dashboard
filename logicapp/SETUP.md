# Logic App setup

This is click-ops intentionally — the Office 365 Outlook connector needs an
interactive OAuth consent to the shared mailbox owner, so ARM/Bicep deployment
of the API connection is awkward. Clicking it together takes ~3 minutes.

## Prerequisites

- Shared mailbox exists in M365, e.g. `dmarc@yourdomain.com`.
- Your user account (or a service account) has **Full Access** to the shared
  mailbox. Grant via Exchange admin center → Recipients → Mailboxes → select
  shared mailbox → Delegation → Read and manage.
- Bicep has been deployed — you have the storage account name from the output.

## Create the Logic App

1. Portal → **Logic apps** → **Add** → **Consumption**.
   - Name: `la-dmarc-ingest`
   - Resource group: `rg-dmarc`
   - Region: West Europe
   - Plan type: **Consumption**
2. After creation → **Identity** → System assigned → **On** → Save.
3. **Access control (IAM) on the storage account** (not the Logic App):
   - Add role assignment → **Storage Blob Data Contributor**
   - Assign to → Managed identity → pick `la-dmarc-ingest`

## Build the workflow

Open the Logic App → **Logic app designer** → start with a blank workflow.

### Step 1 — Trigger

- Connector: **Office 365 Outlook**
- Trigger: **When a new email arrives in a shared mailbox (V2)**
- Sign in with the account that has Full Access to `dmarc@yourdomain.com`.
- Parameters:
  - **Mailbox Address**: `dmarc@yourdomain.com`
  - **Folder**: `Inbox`
  - Advanced parameters:
    - **Has Attachment**: `Yes`
    - **Include Attachments**: `Yes`
    - **Importance**: `Any`

### Step 2 — For each attachment

- Add action → **Control** → **For each**
- Select output from previous steps: **Attachments** (from the trigger)

Inside the loop, add:

### Step 2a — Create blob

- Connector: **Azure Blob Storage**
- Action: **Create blob (V2)**
- Connection: click **Connect with managed identity**
  - Connection name: `azureblob-mi`
  - Authentication type: **Logic Apps Managed Identity**
- Parameters:
  - **Storage account name or blob endpoint**: `https://<storage-name>.blob.core.windows.net`
  - **Folder path**: `/raw`
  - **Blob name**: use an expression to prevent collisions:
    ```
    @{formatDateTime(utcNow(),'yyyyMMdd-HHmmss')}-@{items('For_each')?['Name']}
    ```
  - **Blob content**: `@{items('For_each')?['ContentBytes']}`

### Step 3 (optional) — Mark email as read

- Connector: **Office 365 Outlook**
- Action: **Mark as read or unread (V2)**
- Mailbox Address: `dmarc@yourdomain.com`
- Message Id: `@{triggerOutputs()?['body/id']}`
- Mark as: **Read**

This keeps the shared mailbox tidy and prevents re-triggering on the same email.

## Test

1. Send a test email to the shared mailbox with any DMARC XML (or zip/gz) attached.
2. Watch the Logic App **Run history** — it should fire within a minute.
3. Check the storage account → `raw` container → the file should be there.
4. Within ~1 minute (blob trigger polling latency on Consumption plan) the
   Function runs and updates `$web/index.html`.
5. Browse to the static website URL (from Bicep output `staticWebsiteUrl`).

## Troubleshooting

- **Trigger doesn't fire**: verify Full Access permission on the shared mailbox
  has fully propagated (can take 15-60 minutes for fresh grants).
- **"Unauthorized" on blob create**: the managed identity role assignment
  needs ~5 minutes to propagate.
- **Function doesn't run**: check Function App → Functions → ProcessDmarc →
  Monitor. The blob trigger uses polling on Consumption plan, so latency can
  be up to 10 minutes for the first blob after a cold start.
- **Dashboard not updating**: check Function logs in Application Insights.
  Most common issue: the Az module hasn't installed yet on first cold start
  (managed dependency install takes ~2-3 minutes the very first time).
