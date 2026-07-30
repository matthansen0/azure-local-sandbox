targetScope = 'subscription'

@description('Azure region for the outer sandbox resources. The selected region must offer the requested VM size.')
param location string

@description('Supported Azure Local region used for Arc registration and cluster resources. This can differ from the outer host region.')
param azureLocalLocation string = location

@description('Resource group created for the sandbox.')
@minLength(1)
@maxLength(90)
param resourceGroupName string = 'rg-azure-local-sandbox'

@description('Prefix used for Azure resource names.')
@minLength(2)
@maxLength(40)
param namePrefix string = 'localbox'

@description('Local administrator username for LocalBox-Client.')
param adminUsername string = 'localadmin'

@description('Local administrator password for LocalBox-Client.')
@secure()
@minLength(12)
@maxLength(123)
param adminPassword string

@description('Azure VM size for LocalBox-Client.')
@allowed([
  'Standard_E32s_v5'
  'Standard_E32s_v6'
])
param vmSize string = 'Standard_E32s_v6'

@description('Exact Windows Server image version resolved before deployment. The value latest is not accepted.')
param hostImageVersion string

@description('Deploy Azure Bastion for private RDP access. Disabling Bastion leaves the VM accessible only through another private network path or Azure Serial Console.')
param deployBastion bool = true

@description('Azure Bastion SKU. Developer is free but is offered only in a subset of regions. Deploy.ps1 falls back to Standard where Developer is unavailable.')
@allowed([
  'Developer'
  'Basic'
  'Standard'
])
param bastionSku string = 'Developer'

@description('Run Bootstrap.ps1 through the Custom Script Extension.')
param deployBootstrap bool = true

@description('Public HTTPS URI for the bootstrap script. Override this when deploying a branch or fork.')
@secure()
param bootstrapScriptUri string

@description('SHA-256 of Bootstrap.ps1 at bootstrapScriptUri.')
@minLength(64)
@maxLength(64)
param bootstrapScriptSha256 string

@description('Public HTTPS ZIP archive containing this repository. Bootstrap extracts it to C:\\AzureLocalSandbox\\Source.')
@secure()
param sourceArchiveUri string

@description('SHA-256 of the ZIP at sourceArchiveUri.')
@minLength(64)
@maxLength(64)
param sourceArchiveSha256 string

@description('Grant the VM managed identity Owner on the sandbox resource group for later Azure Local registration and role assignments.')
param grantSandboxOwnerRole bool = true

@description('Tenant-specific object ID of the Azure Local resource provider service principal.')
param hciResourceProviderObjectId string

@description('Tags applied to sandbox resources.')
param tags object = {
  environment: 'sandbox'
  project: 'azure-local-sandbox'
}

resource sandboxResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  name: '${namePrefix}-network'
  scope: sandboxResourceGroup
  params: {
    deployBastion: deployBastion
    bastionSku: bastionSku
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module host 'modules/host.bicep' = {
  name: '${namePrefix}-host'
  scope: sandboxResourceGroup
  params: {
    adminPassword: adminPassword
    adminUsername: adminUsername
    bootstrapScriptSha256: bootstrapScriptSha256
    bootstrapScriptUri: bootstrapScriptUri
    deployBootstrap: deployBootstrap
    grantSandboxOwnerRole: grantSandboxOwnerRole
    hciResourceProviderObjectId: hciResourceProviderObjectId
    imageVersion: hostImageVersion
    azureLocalLocation: azureLocalLocation
    location: location
    namePrefix: namePrefix
    resourceGroupName: sandboxResourceGroup.name
    sourceArchiveUri: sourceArchiveUri
    sourceArchiveSha256: sourceArchiveSha256
    subnetId: network.outputs.hostSubnetId
    subscriptionId: subscription().subscriptionId
    tags: tags
    tenantId: tenant().tenantId
    vmSize: vmSize
  }
}

output bastionName string = network.outputs.bastionName
output bastionSku string = network.outputs.bastionSku
output hostManagedIdentityPrincipalId string = host.outputs.managedIdentityPrincipalId
output hostPrivateIpAddress string = host.outputs.privateIpAddress
output hostVirtualMachineId string = host.outputs.virtualMachineId
output resourceGroupName string = sandboxResourceGroup.name