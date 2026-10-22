param logicAppName string
param servicePlanName string
param environment string
param locationCode string
param location string
param tags object
param serviceBusNamespaceName string
param apimBaseUrl string
param logAnalyticsWorkspaceId string
param sharedKeyVaultName string

// ── Blob storage account names (per container type) ───────────────────────────
// All default to the same data account. Set independently to split containers
// across separate storage accounts — the Logic App MI requires the appropriate
// Storage Blob Data Contributor role on each target account.

param blobStagingAccountName string
param blobRecordsAccountName string
param blobQuarantineAccountName string
param tableStorageAccountName string

param blobStagingContainerName string
param blobRecordsContainerName string
param blobQuarantineContainerName string
param sbusTopicDlvRequests string
param sbusSubDlvRequests string
param sbusTopicNotifications string
param sharePointConnectionRuntimeUrl string
param sharePointConnectionResourceId string = ''
param appInsightsConnectionStringSecretUri string
param appInsightsInstrumentationKeySecretUri string
param apimSubscriptionKeySecretUri string
param acsEmailEndpointSecretUri string
param acsEmailSenderAddress string
param correlationIdHeader string = 'X-Correlation-ID'
param whitespaceApiAudienceId string = ''

// ── Logic App backing (config) storage ────────────────────────────────────────
// Hosts Logic App state, artifact cache, and workflow definitions at runtime.
// Naming: sta + locationCode + dts + config + env
// Network access restrictions are applied manually by the infrastructure team.

var configStorageName = 'sta${locationCode}dtsconfig${environment}'

resource configStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: configStorageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// ── App Service Plan ───────────────────────────────────────────────────────────

resource servicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: servicePlanName
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  kind: 'windows'
  properties: {
    targetWorkerCount: 1
    targetWorkerSizeId: 0
    maximumElasticWorkerCount: 20
  }
}

// ── Logic App Standard ─────────────────────────────────────────────────────────
// Config storage is accessed via Managed Identity (no shared-key connection string).
// ARM skips storage connectivity validation during deployment; the runtime connects
// once the infra team has assigned the required roles to the Logic App MI (step 3.1).

resource logicApp 'Microsoft.Web/sites@2022-09-01' = {
  name: logicAppName
  location: location
  tags: tags
  kind: 'workflowapp,functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: servicePlan.id
    httpsOnly: true
    siteConfig: {
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        // ── Runtime infrastructure ────────────────────────────────────────────
        { name: 'FUNCTIONS_EXTENSION_VERSION',  value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',     value: 'node' }
        { name: 'APP_KIND',                     value: 'workflowapp' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',     value: '1' }
        // MI-based config storage — avoids shared-key auth; ARM won't validate
        // storage connectivity during deployment. Roles assigned post-deploy (step 3.1).
        { name: 'AzureWebJobsStorage__accountName',                      value: configStorage.name }
        { name: 'AzureWebJobsStorage__credential',                       value: 'managedidentity' }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName',  value: configStorage.name }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__credential',   value: 'managedidentity' }
        { name: 'WEBSITE_CONTENTSHARE',                                   value: logicAppName }
        { name: 'AzureFunctionsJobHost__extensionBundle__id',      value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        // ── Observability ─────────────────────────────────────────────────────
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: '@Microsoft.KeyVault(SecretUri=${appInsightsConnectionStringSecretUri})' }
        { name: 'appinsights_instrumentation_key',        value: '@Microsoft.KeyVault(SecretUri=${appInsightsInstrumentationKeySecretUri})' }
        // ── External services (KV-backed secrets) ─────────────────────────────
        { name: 'apim_subscription_key', value: '@Microsoft.KeyVault(SecretUri=${apimSubscriptionKeySecretUri})' }
        { name: 'acs_email_endpoint',    value: '@Microsoft.KeyVault(SecretUri=${acsEmailEndpointSecretUri})' }
        { name: 'acs_email_sender_address', value: acsEmailSenderAddress }
        // ── Runtime behaviour ──────────────────────────────────────────────────
        { name: 'correlation_id_header',      value: correlationIdHeader }
        { name: 'whitespace_api_audience_id', value: whitespaceApiAudienceId }
        // ── Managed API connections (SharePoint Online) ────────────────────────
        { name: 'sharepoint_api_id',               value: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/sharepointonline' }
        { name: 'sharepoint_connection_id',         value: sharePointConnectionResourceId }
        { name: 'sharepoint_connection_runtime_url', value: sharePointConnectionRuntimeUrl }
        // ── DTS infrastructure bindings ────────────────────────────────────────
        { name: 'servicebus_fully_qualified_namespace', value: '${serviceBusNamespaceName}.servicebus.windows.net' }
        { name: 'sbus_topic_dlv_requests',  value: sbusTopicDlvRequests }
        { name: 'sbus_sub_dlv_requests',    value: sbusSubDlvRequests }
        { name: 'sbus_topic_notifications', value: sbusTopicNotifications }
        // ── Blob storage (per-container account names) ────────────────────────
        { name: 'blob_staging_account_name',    value: blobStagingAccountName }
        { name: 'blob_records_account_name',    value: blobRecordsAccountName }
        { name: 'blob_quarantine_account_name', value: blobQuarantineAccountName }
        { name: 'blob_staging_container',       value: blobStagingContainerName }
        { name: 'blob_records_container',       value: blobRecordsContainerName }
        { name: 'blob_quarantine_container',    value: blobQuarantineContainerName }
        // ── Table storage ──────────────────────────────────────────────────────
        { name: 'datastore_table_storage_account_name', value: tableStorageAccountName }
        // ── Key Vault ──────────────────────────────────────────────────────────
        { name: 'key_vault_name', value: sharedKeyVaultName }
        // ── Business configuration ─────────────────────────────────────────────
        { name: 'environment_name', value: environment }
        { name: 'apim_base_url',    value: apimBaseUrl }
      ]
    }
  }
}

// ── Diagnostic settings ────────────────────────────────────────────────────────

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: logicApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'WorkflowRuntime'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────────

output logicAppName string            = logicApp.name
output logicAppId string              = logicApp.id
output logicAppDefaultHostname string = logicApp.properties.defaultHostName
output logicAppPrincipalId string     = logicApp.identity.principalId
output servicePlanId string           = servicePlan.id
output configStorageAccountName string = configStorage.name
