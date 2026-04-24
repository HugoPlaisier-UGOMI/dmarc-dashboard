# Entra ID authentication setup

Once the infra is deployed (stage 1), you wire up Easy Auth so only
authenticated Entra ID users can reach `/api/dashboard`.

## 1. Create the Entra app registration

You need the Function App's default hostname first - grab it from the
stage 1 Bicep output `functionAppHostname`, e.g. `dmarc-func-abcd12.azurewebsites.net`.

```bash
FUNC_HOST="dmarc-func-abcd12.azurewebsites.net"

# Create the app registration
APP_ID=$(az ad app create \
  --display-name "DMARC Dashboard" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://$FUNC_HOST/.auth/login/aad/callback" \
  --enable-id-token-issuance true \
  --query appId -o tsv)

echo "App ID: $APP_ID"

# Add the Function App's app URL as the identifier URI
az ad app update --id $APP_ID --identifier-uris "api://$APP_ID"

# Generate a client secret (valid 2 years)
SECRET=$(az ad app credential reset \
  --id $APP_ID \
  --display-name "easyauth" \
  --years 2 \
  --query password -o tsv)

echo "Client secret (save this now, you won't see it again):"
echo $SECRET
```

## 2. Set the client secret as an app setting on the Function App

Easy Auth expects the secret in an app setting whose name matches
`clientSecretSettingName` in the Bicep (`MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`).

```bash
az functionapp config appsettings set \
  --name <functionAppName> \
  --resource-group rg-dmarc \
  --settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$SECRET"
```

## 3. Restrict who can sign in (optional but recommended)

By default any user in your tenant can sign in. To restrict to specific
users/groups:

1. Portal → **Entra ID** → **Enterprise applications** → find "DMARC Dashboard"
2. **Properties** → set **Assignment required** to **Yes** → Save
3. **Users and groups** → **Add user/group** → pick yourself or an M365 group

Now only assigned principals can get past Easy Auth.

## 4. Re-deploy Bicep with auth enabled

```bash
az deployment group create \
  -g rg-dmarc \
  -f infra/main.bicep \
  -p namePrefix=dmarc entraClientId=$APP_ID
```

This adds the `authsettingsV2` resource which flips Easy Auth on.

## 5. Test

Browse to `https://<functionAppHostname>/api/dashboard`. You should be
redirected to `login.microsoftonline.com`, sign in with your work account,
and land back on the dashboard.

To sign out: `https://<functionAppHostname>/.auth/logout`
To see your identity headers: `https://<functionAppHostname>/.auth/me`

## Secret rotation

The client secret expires in 2 years. Set a calendar reminder. When it
expires, repeat the `az ad app credential reset` + app setting update.

Alternatively, switch to a **federated credential** scenario - but Easy
Auth on Function App doesn't support federated credentials for the auth
provider itself, only client secrets or certificates. A certificate with a
longer validity is a middle ground if you want less frequent rotation.
