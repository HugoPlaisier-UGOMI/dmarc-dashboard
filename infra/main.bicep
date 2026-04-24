// =============================================================================
// DMARC Dashboard - Infra (v3: Windows Consumption, working baseline)
//
// Stack:
//   - Storage account (private containers, but allowBlobPublicAccess=true to
//     allow Functions runtime + Logic App MI access via shared key when needed)
//   - Function App: Windows Consumption, 64-bit, PowerShell 7.4
//   - AzureWebJobsStorage via connection string (most reliable on Windows Consumption)
//   - Function MI still gets Blob Data Owner so the function CODE uses identity
//     for the actual data containers (raw, dashboard) - only the Functions
//     runtime state uses the connection string
//   - Application Insights for telemetry
//   - Conditional Easy Auth V2 binding when entraClientId is provided
//
// Deploy (stage 1 - without Entra auth):
//   az deployment group create -g rg-dmarc -f main.bicep -p namePrefix=dmarc
//
// Deploy (stage 2 - with Entra auth):
//   az deployment group create -g rg-dmarc -f main.bicep `
//     -p namePrefix=dmarc entraClientId=<appId>
// =============================================================================

@description('Prefix for all resource names. Lowercase, 3-11 chars.')
@minLength(3)
@maxLength(11)
param namePrefix string = 'dmarc'

@description('Azure region.')
param location string = 'westeurope'

@description('Object ID of the user or group that should administer the storage account.')
param adminPrincipalId string = ''

@description('Entra ID application (client) ID for Easy Auth. Leave empty in stage 1.')
param entraClientId string = ''

@description('Entra ID tenant ID for Easy Auth. Defaults to current tenant.')
param entraTenantId string = tenant().tenantId

var suffix          = uniqueString(resourceGroup().id)
var storageName     = toLower('st${namePrefix}${take(suffix, 8)}')
var functionAppName = '${namePrefix}-func-${take(suffix, 6)}'
var planName        = '${namePrefix}-plan-${take(suffix, 6)}'
var appInsightsName = '${namePrefix}-ai-${take(suffix, 6)}'
var rawContainer    = 'raw'
var dashContainer   = 'dashboard'
var contentShare    = toLower('${functionAppName}-content')

var enableAuth = !empty(entraClientId)

// Built-in role definition IDs
var roleStorageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

// -----------------------------------------------------------------------------
// Storage account
// -----------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false   // containers stay private, no anonymous access
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true     // required for connection-string based AzureWebJobsStorage
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource rawContainerRes 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: rawContainer
  properties: { publicAccess: 'None' }
}

resource dashContainerRes 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: dashContainer
  properties: { publicAccess: 'None' }
}

// Connection string for the Functions runtime
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'

// -----------------------------------------------------------------------------
// Application Insights
// -----------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    IngestionMode: 'ApplicationInsights'
  }
}

// -----------------------------------------------------------------------------
// Function App - Windows Consumption, PowerShell 7.4, 64-bit
// -----------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
  kind: 'functionapp'
  properties: {
    reserved: false   // Windows
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      use32BitWorkerProcess: false   // PowerShell 7.4 is 64-bit only
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION',           value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',              value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION',      value: '7.4' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // Functions runtime state via connection string (most reliable)
        { name: 'AzureWebJobsStorage',                       value: storageConnectionString }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING',  value: storageConnectionString }
        { name: 'WEBSITE_CONTENTSHARE',                      value: contentShare }
        // Custom app settings consumed by function code
        { name: 'STORAGE_ACCOUNT',     value: storage.name }
        { name: 'RAW_CONTAINER',       value: rawContainer }
        { name: 'DASHBOARD_CONTAINER', value: dashContainer }
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// Easy Auth V2 - only configured once entraClientId is provided
// -----------------------------------------------------------------------------
// NOTE: before this deploys successfully, you must also set the app setting
// MICROSOFT_PROVIDER_AUTHENTICATION_SECRET on the Function App with the
// client secret from your Entra app registration. See docs/ENTRA-AUTH.md.
resource authSettings 'Microsoft.Web/sites/config@2023-12-01' = if (enableAuth) {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: '${environment().authentication.loginEndpoint}${entraTenantId}/v2.0'
          clientId: entraClientId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
        }
        validation: {
          allowedAudiences: [
            'api://${entraClientId}'
          ]
        }
      }
    }
    login: {
      tokenStore: { enabled: true }
      preserveUrlFragmentsForLogins: false
    }
  }
}

// -----------------------------------------------------------------------------
// Role assignments
// -----------------------------------------------------------------------------
// Function MI: Blob Data Owner - the function CODE uses managed identity
// (-UseConnectedAccount) to read raw blobs and write dashboard/index.html.
// AzureWebJobsStorage runtime state uses the connection string instead.
resource funcBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, 'blob-owner')
  scope: storage
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
  }
}

// Admin user gets Blob Data Owner so you can manage blobs from your laptop
resource adminBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminPrincipalId)) {
  name: guid(storage.id, adminPrincipalId, 'admin-blob')
  scope: storage
  properties: {
    principalId: adminPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
  }
}

// =============================================================================
// Outputs
// =============================================================================
output storageAccountName  string = storage.name
output functionAppName     string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output dashboardUrl        string = 'https://${functionApp.properties.defaultHostName}/api/dashboard'
output rawContainer        string = rawContainer
output dashboardContainer  string = dashContainer
