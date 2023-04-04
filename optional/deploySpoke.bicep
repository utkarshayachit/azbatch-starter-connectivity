//------------------------------------------------------------------------------
// Note: 
//
// Objects are deployed using the Quick Start Bicep Library
//
// Please find the full repo incl. documentation here: https://github.com/Azure/ResourceModules/
//------------------------------------------------------------------------------

targetScope = 'resourceGroup'

//------------------------------------------------------------------------------
// Options: parameters having broad impact on the deployement.
//------------------------------------------------------------------------------

@description('location where all the resources are to be deployed')
param location string = resourceGroup().location

@description('short string used to identify deployment environment')
@minLength(3)
@maxLength(10)
param environment string = 'dev'

@description('short string used to generate all resources')
@minLength(5)
@maxLength(13)
param prefix string = uniqueString(environment, subscription().id, location)

@description('string used as salt for generating unique suffix for all resources')
param suffixSalt string = ''

@description('additonal tags to attach to resources created')
param tags object = {}

@description('when true, all resources will be deployed under a single resource-group')
param useSingleResourceGroup bool = false


@description('deployment timestamp')
param timestamp string = utcNow('g')

//------------------------------------------------------------------------------
// Load exteranl configuration objects
//------------------------------------------------------------------------------

@description('hub configuration')
param hubConfig object = loadJsonContent('../config/hub.jsonc')

@description('spoke configuration')
param spokeConfig object = loadJsonContent('./config/spoke.jsonc')

@description('Private DNS Zone Configuration')
param pdnsZoneConfigBase string = loadTextContent('../config/privateDnszone.json')

@description('Load diagnostic settings')
param diagnosticConfig object = loadJsonContent('../config/diagnostics.json')

//------------------------------------------------------------------------------
// Features: additive components
//------------------------------------------------------------------------------
// none available currently


//------------------------------------------------------------------------------
// Variables
//------------------------------------------------------------------------------

var suffix = empty(suffixSalt) ? '' : '-${uniqueString(suffixSalt)}'

@description('resources prefix')
var rsPrefix = '${environment}-${prefix}${suffix}'

@description('deployments prefix')
var dplPrefix = 'dpl-${environment}-${prefix}${suffix}'

@description('tags for all resources')
var allTags = union(tags, {
  'last deployed': timestamp
  source: 'azbatch-starter-connectivity:v0.1'
})

@description('resource group names')
var resourceGroupNames = {

  networkHubRG: {
    name: useSingleResourceGroup? 'rg-${rsPrefix}' : 'rg-${rsPrefix}-hub-01'
    enabled: true
  }

  networkSpokeRG: {
    name: useSingleResourceGroup? 'rg-${rsPrefix}' : 'rg-${rsPrefix}-spoke-01'
    enabled: true
  }

}


// Transform the diagnostic settings config values in the appropriate format

var enabledLogs = filter(diagnosticConfig.logs, item => item.enabled)
var enabledLogsCategories = map(enabledLogs, item => item.categoryGroup)

var enabledMetrics = filter(diagnosticConfig.metrics, item => item.enabled)
var enabledMetricsCategories = map(enabledMetrics, item => item.category)

// Retention Days are only read from the logs settings
var retentionDaysRaw = map(enabledLogs, item => item.retentionPolicy.enabled ? item.retentionPolicy.days : 0)
var retentionDays = max(union(retentionDaysRaw,[10]))


//------------------------------------------------------------------------------
// Resources
//------------------------------------------------------------------------------

// Get the reference to Log Analytics Workspace in the Hub resource group

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' existing = {
  name: 'log-${rsPrefix}' 
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
}

// Deploy a Default NSG Rule which is used for all subnets

@description('Deploy default NSG')
module spokeDefaultNSG '../modules/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkSpokeRG.name)
  name: '${dplPrefix}-spoke-network-nsg-default'
  params: {
    name: 'nsg-${rsPrefix}-default'
    location: location
    securityRules: spokeConfig.networkSecurityGroups.defaultNSG
    tags: allTags
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.id
  }
}

// Deploy the Spoke Network and peer it with the hub network
//------------------------------------------------------------------------------

var txtSpokeConfig_base = loadTextContent('config/spoke.jsonc')
var txtSpokeConfig_nsg_default = replace(txtSpokeConfig_base, '--nsg-default--', '${spokeDefaultNSG.outputs.resourceId}')


var spokeSubnets = json(txtSpokeConfig_nsg_default).spokeNetwork.subnets.value


resource vnetHub 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: 'vn-${rsPrefix}-hub-01'
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
}


// TODO: Check Gateway transit setting

var hubSpokePeering = [
  
  {
    allowForwardedTraffic: true
    allowGatewayTransit: false
    allowVirtualNetworkAccess: true
    remotePeeringAllowForwardedTraffic: true
    remotePeeringAllowVirtualNetworkAccess: true
    remotePeeringEnabled: true
    remotePeeringName: 'peer-${rsPrefix}-hubSpoke01'
    remoteVirtualNetworkId: vnetHub.id
    useRemoteGateways: false
  }

]

@description('Deploy spoke virtual network incl. subnets')
module SpokeVnet '../modules/Microsoft.Network/virtualNetworks/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkSpokeRG.name)
  name: '${dplPrefix}-spoke-01-network-vnet'
  params: {
    addressPrefixes: contains(spokeConfig, 'spokeNetwork') ? spokeConfig.spokeNetwork.addressPrefixes.value : {}
    subnets: spokeSubnets
    name: 'vn-${rsPrefix}-spoke-01'
    location: location
    virtualNetworkPeerings: hubSpokePeering
    tags: allTags
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticMetricsToEnable: enabledMetricsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.id
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    spokeDefaultNSG
  ]
}

//  Link the Spoke Network to the private DNS Zone in the Hub
//------------------------------------------------------------------------------


output hubID string = vnetHub.id
output hubGuid string = vnetHub.properties.resourceGuid
