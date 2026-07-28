@description('Azure region for the network resources.')
param location string

@description('Prefix used for resource names.')
@minLength(2)
@maxLength(40)
param namePrefix string = 'localbox'

@description('Deploy Azure Bastion for private RDP access to the sandbox host.')
param deployBastion bool = true

@description('Address space for the Azure virtual network. Nested Hyper-V networks must not overlap this range.')
param virtualNetworkAddressPrefix string = '172.31.0.0/16'

@description('Address prefix for the outer LocalBox host subnet.')
param hostSubnetAddressPrefix string = '172.31.1.0/24'

@description('Address prefix for Azure Bastion. Azure Bastion requires a /26 or larger subnet named AzureBastionSubnet.')
param bastionSubnetAddressPrefix string = '172.31.2.0/26'

@description('Tags applied to all network resources.')
param tags object = {}

var virtualNetworkName = '${namePrefix}-vnet'
var hostSubnetName = '${namePrefix}-host-subnet'
var networkSecurityGroupName = '${namePrefix}-host-nsg'
var natGatewayName = '${namePrefix}-nat'
var bastionName = '${namePrefix}-bastion'

resource hostNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: networkSecurityGroupName
  location: location
  tags: tags
}

resource natGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${natGatewayName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 10
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natGatewayPublicIp.id
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
  }
}

resource hostSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: hostSubnetName
  properties: {
    addressPrefix: hostSubnetAddressPrefix
    defaultOutboundAccess: false
    networkSecurityGroup: {
      id: hostNetworkSecurityGroup.id
    }
    natGateway: {
      id: natGateway.id
    }
  }
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (deployBastion) {
  parent: virtualNetwork
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: bastionSubnetAddressPrefix
    defaultOutboundAccess: false
  }
}

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployBastion) {
  name: '${bastionName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastionHost 'Microsoft.Network/bastionHosts@2024-05-01' = if (deployBastion) {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ip-configuration'
        properties: {
          publicIPAddress: {
            id: bastionPublicIp.id
          }
          subnet: {
            id: bastionSubnet.id
          }
        }
      }
    ]
  }
}

output hostSubnetId string = hostSubnet.id
output virtualNetworkId string = virtualNetwork.id
output bastionName string = deployBastion ? bastionHost.name : ''