# GitHub setup (first project)

This is a walkthrough for getting this project into a GitHub repo with
automatic Azure deploys, assuming you've got a GitHub account but never
used it. It's not a generic Git tutorial — it focuses on what you need
for this case.

## Mental model in 60 seconds

- **Git** = local version control. Every change becomes a **commit**;
  commits form a history; **branches** are named pointers into that
  history (you'll mostly use `main`).
- **GitHub** = a hosted place to store your Git history. You **push**
  local commits to a GitHub **repository**, and **pull** commits from
  other contributors (or future-you on another machine).
- **GitHub Actions** = scripts that run on GitHub's servers in response
  to events (push, PR, schedule). Ours runs on push to `main` and deploys
  the Bicep + Function code to Azure.
- **OIDC federated credentials** = the way we let GitHub Actions log into
  your Azure tenant without storing any secrets. GitHub issues a short-lived
  token, Azure trusts it because of a federated credential on an Entra app
  registration. No passwords, no rotation.

## 1. Install Git + sign in

```powershell
winget install --id Git.Git
git --version

# Tell git who you are (shows up on commits)
git config --global user.name  "Hugo"
git config --global user.email "hugo@yourdomain.com"
git config --global init.defaultBranch main
```

Install GitHub CLI as well — it makes repo creation and auth painless:

```powershell
winget install --id GitHub.cli
gh auth login   # follow the prompts, pick HTTPS + browser login
```

## 2. Create the GitHub repository

From inside the `dmarc-dashboard` folder:

```powershell
cd C:\path\to\dmarc-dashboard

# Initialize local git repo
git init
git add .
git commit -m "Initial commit: DMARC dashboard on Azure"

# Create a private repo on GitHub and push
gh repo create dmarc-dashboard --private --source=. --remote=origin --push
```

You now have `https://github.com/<your-user>/dmarc-dashboard`.

## 3. Create the Entra app registration for GitHub Actions

This is a **different** app registration from the one for Easy Auth — keep
them separate. This one exists only so GitHub can authenticate to Azure.

```bash
# Variables
GH_USER="<your github username>"
REPO="dmarc-dashboard"
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# Create the app
GH_APP_ID=$(az ad app create \
  --display-name "GitHub Actions - dmarc-dashboard" \
  --query appId -o tsv)

# Create the service principal
az ad sp create --id $GH_APP_ID

# Add federated credential tying this app to your GitHub repo's main branch
az ad app federated-credential create \
  --id $GH_APP_ID \
  --parameters "{
    \"name\": \"github-main\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$GH_USER/$REPO:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

# Grant Contributor on the resource group
az role assignment create \
  --assignee $GH_APP_ID \
  --role Contributor \
  --scope /subscriptions/$SUB_ID/resourceGroups/rg-dmarc

# The Bicep also creates role assignments on the storage account, which
# requires User Access Administrator at the RG level. Grant that too.
az role assignment create \
  --assignee $GH_APP_ID \
  --role "User Access Administrator" \
  --scope /subscriptions/$SUB_ID/resourceGroups/rg-dmarc

echo "App ID:      $GH_APP_ID"
echo "Tenant ID:   $TENANT_ID"
echo "Sub ID:      $SUB_ID"
```

## 4. Add the three Actions secrets to GitHub

Using the GitHub CLI so you never paste them into a browser form:

```powershell
gh secret set AZURE_CLIENT_ID       --body "<GH_APP_ID from step 3>"
gh secret set AZURE_TENANT_ID       --body "<TENANT_ID from step 3>"
gh secret set AZURE_SUBSCRIPTION_ID --body "<SUB_ID from step 3>"

# After you've completed docs/ENTRA-AUTH.md and have an Easy Auth app ID:
gh secret set ENTRA_CLIENT_ID       --body "<APP_ID from ENTRA-AUTH.md>"
```

Verify:

```powershell
gh secret list
```

## 5. Push a change and watch it deploy

```powershell
# Make any trivial change, e.g. tweak the README
git add .
git commit -m "Trigger first deploy"
git push

# Watch the workflow run
gh run watch
```

Or in the browser: **your repo → Actions tab**. First run takes ~4-5
minutes (most of it is the Function publish + managed dependency install).

## Day-to-day workflow

Once this is set up, making changes looks like:

```powershell
# Edit a file, e.g. adjust the HTML in function/ProcessDmarc/run.ps1
code function/ProcessDmarc/run.ps1

# Stage + commit + push
git add function/ProcessDmarc/run.ps1
git commit -m "Tweak dashboard: add SPF-only breakdown"
git push

# Actions picks it up automatically, ~2 min later the change is live
```

Useful commands:

```powershell
git status                  # what's changed since the last commit
git diff                    # show the actual changes
git log --oneline -n 10     # recent history
git pull                    # grab any changes from GitHub (e.g. if you edited in the web UI)
gh run list                 # recent workflow runs
gh run view --log-failed    # diagnose a failed deploy
```

## Branches and pull requests (when you're ready)

For a solo project on `main` this is overkill, but the next step up is:

```powershell
git checkout -b feature/add-chart
# make changes
git commit -am "Add weekly trend chart"
git push -u origin feature/add-chart
gh pr create --fill
```

Then review your own PR, merge it in the web UI, and the workflow runs.
This gives you a proper audit trail and lets you undo a bad change by
reverting the PR.

## Things to know / watch for

- **Never commit secrets.** Double-check `git status` before committing.
  The `.gitignore` catches common cases but isn't foolproof. If you
  accidentally commit a secret, rotate it immediately — assume it's
  compromised even if you force-push to remove it.
- **Private repo matters here** because the Bicep references storage
  account names and your naming conventions. Public wouldn't leak
  credentials but would give anyone a map of your setup.
- **Federated credentials are bound to `refs/heads/main`**. If you rename
  the branch or deploy from a different branch, you need a new federated
  credential with a matching subject.
- **The Entra app for Easy Auth has a client secret** (see
  `docs/ENTRA-AUTH.md`) which DOES need rotation in 2 years. That's
  separate from the GitHub OIDC app, which uses federation and never needs
  rotation.
