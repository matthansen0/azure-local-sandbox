@description('Azure region for the LocalBox host.')
param location string

@description('Prefix used for resource names.')
@minLength(2)
@maxLength(40)
param namePrefix string = 'localbox'

@description('Name of the outer Azure VM that hosts the nested lab.')
param vmName string = 'LocalBox-Client'

@description('Azure VM size. These SKUs provide the 32 vCPUs and nested virtualization support required by the two-node lab.')
@allowed([
  'Standard_E32s_v5'
  'Standard_E32s_v6'
])
param vmSize string = 'Standard_E32s_v6'

@description('Exact Windows Server marketplace image version.')
param imageVersion string

@description('Local administrator username for the outer Azure VM.')
param adminUsername string

@description('Local administrator password for the outer Azure VM. This value is never passed to bootstrap scripts.')
@secure()
@minLength(12)
@maxLength(123)
param adminPassword string

@description('Resource ID of the subnet for the outer Azure VM.')
param subnetId string

@description('Public HTTPS URI for Bootstrap.ps1. The Custom Script Extension downloads this file directly.')
@secure()
param bootstrapScriptUri string

@description('Expected SHA-256 of the downloaded bootstrap script.')
@minLength(64)
@maxLength(64)
param bootstrapScriptSha256 string

@description('Public HTTPS ZIP archive containing the complete sandbox source tree.')
@secure()
param sourceArchiveUri string

@description('Expected SHA-256 of the downloaded source archive.')
@minLength(64)
@maxLength(64)
param sourceArchiveSha256 string

@description('Run the host bootstrap Custom Script Extension.')
param deployBootstrap bool = true

@description('Grant the VM managed identity Owner on the sandbox resource group. Later Azure Local registration requires role assignment permissions.')
param grantSandboxOwnerRole bool = true

@description('Azure subscription ID written to the nonsecret deployment context on the host.')
param subscriptionId string

@description('Microsoft Entra tenant ID written to the nonsecret deployment context on the host.')
param tenantId string

@description('Sandbox resource group name written to the nonsecret deployment context on the host.')
param resourceGroupName string

@description('Supported Azure Local region used for Arc registration and cluster resources.')
param azureLocalLocation string

@description('Tenant-specific object ID of the Azure Local resource provider service principal.')
param hciResourceProviderObjectId string

@description('Number of managed data disks used for nested VM storage.')
@minValue(4)
@maxValue(8)
param dataDiskCount int = 8

@description('Size in GiB of each nested VM data disk.')
@minValue(128)
param dataDiskSizeGiB int = 1024

@description('Tags applied to host resources.')
param tags object = {}

var networkInterfaceName = '${namePrefix}-host-nic'
var ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
var keyVaultDataAccessAdministratorRoleDefinitionId = '8b54135c-b56d-4d72-a534-26097cfdc8d8'
var keyVaultSecretsOfficerRoleDefinitionId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var encodedSourceArchiveUri = base64(sourceArchiveUri)
var encodedSourceArchiveSha256 = base64(toUpper(sourceArchiveSha256))

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaceName
  location: location
  tags: tags
  properties: {
    // Both permitted E32s SKUs support SR-IOV, which the Arc appliance image download and the nested
    // guest traffic both benefit from.
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Delete'
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-g2'
        version: imageVersion
      }
      osDisk: {
        name: '${vmName}-os'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 1024
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [for diskIndex in range(0, dataDiskCount): {
        name: '${vmName}-data-${diskIndex}'
        lun: diskIndex
        // ReadOnly host caching serves the read-heavy phases (parent image hashing, differencing disk
        // reads) from the host cache, and those hits do not count against the VM's uncached ceiling.
        // ReadWrite is unsafe here because Storage Spaces does not flush the host cache on its own.
        caching: 'ReadOnly'
        createOption: 'Empty'
        deleteOption: 'Delete'
        diskSizeGB: dataDiskSizeGiB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource bootstrapExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (deployBootstrap) {
  parent: virtualMachine
  name: 'Bootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [
        bootstrapScriptUri
      ]
      commandToExecute: 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$actual=(Get-FileHash -LiteralPath .\\Bootstrap.ps1 -Algorithm SHA256).Hash; if ($actual -ne \'${toUpper(bootstrapScriptSha256)}\') { throw \'Bootstrap.ps1 SHA-256 mismatch.\' }; & .\\Bootstrap.ps1 -SubscriptionId \'${subscriptionId}\' -TenantId \'${tenantId}\' -ResourceGroupName \'${resourceGroupName}\' -AzureLocation \'${azureLocalLocation}\' -HciResourceProviderObjectId \'${hciResourceProviderObjectId}\' -SourceArchiveUriBase64 \'${encodedSourceArchiveUri}\' -SourceArchiveSha256Base64 \'${encodedSourceArchiveSha256}\'"'
    }
  }
}

resource sandboxOwnerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantSandboxOwnerRole) {
  name: guid(resourceGroup().id, virtualMachine.id, ownerRoleDefinitionId)
  scope: resourceGroup()
  properties: {
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleDefinitionId)
  }
}

resource keyVaultDataAccessAdministratorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantSandboxOwnerRole) {
  name: guid(resourceGroup().id, virtualMachine.id, keyVaultDataAccessAdministratorRoleDefinitionId)
  scope: resourceGroup()
  properties: {
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultDataAccessAdministratorRoleDefinitionId)
  }
}

resource keyVaultSecretsOfficerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantSandboxOwnerRole) {
  name: guid(resourceGroup().id, virtualMachine.id, keyVaultSecretsOfficerRoleDefinitionId)
  scope: resourceGroup()
  properties: {
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleDefinitionId)
  }
}

output managedIdentityPrincipalId string = virtualMachine.identity.principalId
output privateIpAddress string = networkInterface.properties.ipConfigurations[0].properties.privateIPAddress
output virtualMachineId string = virtualMachine.id
output virtualMachineName string = virtualMachine.name