@description('Azure region for the workspace, data collection rule, and association. A data collection rule must sit in the same region as the virtual machine it is associated with.')
param location string

@description('Prefix used for resource names.')
@minLength(2)
@maxLength(40)
param namePrefix string = 'localbox'

@description('Name of the outer Azure VM that is onboarded to the sandbox workspace.')
param virtualMachineName string

@description('Hard daily ingestion cap in GB. Log Analytics stops ingesting for the remainder of the UTC day once the cap is reached, which bounds the worst-case bill for this workspace.')
@minValue(1)
@maxValue(200)
param dailyQuotaGb int = 5

@description('Interactive retention in days. Values above 31 are billed as extended retention.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Tags applied to monitoring resources.')
param tags object = {}

var workspaceName = '${namePrefix}-law'
var dataCollectionRuleName = '${namePrefix}-host-dcr'
var dataCollectionRuleAssociationName = '${namePrefix}-host-dcra'
var eventLogStream = 'Microsoft-Event'
var logAnalyticsDestinationName = 'sandboxWorkspace'

// Critical, Error, and Warning only. Collecting the Security channel or Information-level events from a
// nested Hyper-V build is what turns a lab into a four-figure ingestion bill.
var eventLogSeverityFilter = '*[System[(Level=1 or Level=2 or Level=3)]]'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// DCR validation resolves built-in streams against workspace tables. Deploy.ps1 retries the exact
// InvalidOutputTable race because the DCR service can lag after this resource reaches Succeeded.
resource eventTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  parent: workspace
  name: 'Event'
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    totalRetentionInDays: retentionInDays
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Sends a filtered Windows event stream from the sandbox host to the sandbox-owned Log Analytics workspace.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'sandboxEventLogs'
          streams: [
            eventLogStream
          ]
          xPathQueries: [
            'System!${eventLogSeverityFilter}'
            'Application!${eventLogSeverityFilter}'
            'Microsoft-Windows-Hyper-V-VMMS-Admin!${eventLogSeverityFilter}'
            'Microsoft-Windows-Hyper-V-Compute-Admin!${eventLogSeverityFilter}'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: logAnalyticsDestinationName
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          eventLogStream
        ]
        destinations: [
          logAnalyticsDestinationName
        ]
      }
    ]
  }
  dependsOn: [
    eventTable
  ]
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: virtualMachineName
}

resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: virtualMachine
  name: 'AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: dataCollectionRuleAssociationName
  scope: virtualMachine
  properties: {
    description: 'Binds the sandbox host to the sandbox-owned data collection rule.'
    dataCollectionRuleId: dataCollectionRule.id
  }
  dependsOn: [
    azureMonitorAgent
  ]
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
output dataCollectionRuleId string = dataCollectionRule.id
