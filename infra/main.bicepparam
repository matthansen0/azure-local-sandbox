using './main.bicep'

param location = 'centralus'
param azureLocalLocation = 'eastus'
param resourceGroupName = 'rg-azure-local-sandbox'
param namePrefix = 'localbox'
param adminUsername = 'localadmin'
param adminPassword = readEnvironmentVariable('AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD')
param vmSize = 'Standard_E32s_v6'
param hostImageVersion = readEnvironmentVariable('AZURE_LOCAL_SANDBOX_HOST_IMAGE_VERSION')
param deployBastion = true
param bastionSku = 'Developer'
param deployBootstrap = true
param deployMonitoring = true
param logAnalyticsDailyQuotaGb = 5
param logAnalyticsRetentionInDays = 30
param bootstrapScriptUri = readEnvironmentVariable('AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI')
param bootstrapScriptSha256 = readEnvironmentVariable('AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256')
param sourceArchiveUri = readEnvironmentVariable('AZURE_LOCAL_SANDBOX_SOURCE_URI')
param sourceArchiveSha256 = readEnvironmentVariable('AZURE_LOCAL_SANDBOX_SOURCE_SHA256')
param grantSandboxOwnerRole = true
param hciResourceProviderObjectId = readEnvironmentVariable('AZURE_LOCAL_RESOURCE_PROVIDER_OBJECT_ID')
param tags = {
  environment: 'sandbox'
  project: 'azure-local-sandbox'
}