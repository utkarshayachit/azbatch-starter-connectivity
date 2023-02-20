targetScope = 'subscription'

//------------------------------------------------------------------------------
// Options: parameters having broad impact on the deployement.
//------------------------------------------------------------------------------

@description('location where all the resources are to be deployed')
param location string = deployment().location

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

@description('Optional. Service Tier: PerGB2018, Free, Standalone, PerGB or PerNode.')
@allowed([
  'Free'
  'Standalone'
  'PerNode'
  'PerGB2018'
])
param serviceTier string = 'PerGB2018'

@description('when true, an Azure Firewall will be deployed')
param deployAzureFirewall bool = false

@description('hub configuration')
param hubConfig object = loadJsonContent('config/hub.jsonc')

@description('deployment timestamp')
param timestamp string = utcNow('g')

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

  connectivityJumpBoxRG: {
    name: useSingleResourceGroup? 'rg-${rsPrefix}' : 'rg-${rsPrefix}-jumpbox'
    enabled: true
  }

}

//------------------------------------------------------------------------------
// Resources
//------------------------------------------------------------------------------

// dev notes: `union()` is used to remove duplicates
var uniqueGroups = union(map(filter(items(resourceGroupNames), arg => arg.value.enabled), arg => arg.value.name), [])

@description('all resource groups')
resource resourceGroups 'Microsoft.Resources/resourceGroups@2021-04-01' = [for name in uniqueGroups: {
  name: name
  location: location
  tags: allTags
}]

//------------------------------------------------------------------------------
// Deploy Log Analytics Workslpace resources

@description('Deploy Log Analytics Workspace')
module logAnalyticsWorkspace './modules/Microsoft.OperationalInsights/workspaces/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-logAnalytics'
  params: {
    name: 'log-${dplPrefix}'
    location: location
    tags: allTags
    serviceTier: serviceTier
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

//------------------------------------------------------------------------------
// Deploy Applicaton Insights resources

@description('Deploy Application Insights Components')
module appInsights './modules/Microsoft.Insights/components/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-appInsights'
  params: {
    name: 'appi-${dplPrefix}'
    workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    location: location
    tags: allTags
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}


//To-Do: How to verify if .bastion rule is part of the NSG config object?

//------------------------------------------------------------------------------
// Process hub network network security groups
// https://github.com/Azure/ResourceModules/

var hasNsg = contains(hubConfig, 'networkSecurityGroups') && length(hubConfig.networkSecurityGroups) > 0

@description('Deploy Hub Bastion NSG')
module hubNSGbastion './modules/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-nsg-bastion'
  params: {
    name: 'nsg-${dplPrefix}-bastion'
    location: location
    tags: allTags
    securityRules: contains(hubConfig, 'networkSecurityGroups') ? hubConfig.networkSecurityGroups.bastion : {}
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

@description('Deploy Hub Bastion NSG')
module hubNSGjumpbox './modules/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-nsg-jumpbox'
  params: {
    name: 'nsg-${dplPrefix}-jumpbox'
    location: location
    tags: allTags
    securityRules: contains(hubConfig, 'networkSecurityGroups') ? hubConfig.networkSecurityGroups.jumpbox : {}
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

@description('nsg rules for hub bastion subnet')
output nsg_bastion array = !hasNsg ? [] : map(range(0, length(hubConfig.networksecurityGroups.bastion)), i => {
   name: contains(hubConfig.networkSecurityGroups.bastion[i], 'name') ? hubConfig.networkSecurityGroups.bastion[i].name : 'nsg_bastion${i}'
   properties: hubConfig.networkSecurityGroups.bastion[i].properties
})

@description('nsg rules for hub jumpbox subnet')
output nsg_jumpbox array = !hasNsg ? [] : map(range(0, length(hubConfig.networksecurityGroups.jumpbox)), i => {
   name: contains(hubConfig.networkSecurityGroups.jumpbox[i], 'name') ? hubConfig.networkSecurityGroups.jumpbox[i].name : 'nsg_jumpbox${i}'
   properties: hubConfig.networkSecurityGroups.jumpbox[i].properties
})

//------------------------------------------------------------------------------
// Process hub network route tables

var hasRoutes = contains(hubConfig, 'networkRoutes') && length(hubConfig.networkRoutes) > 0

@description('Deploy Hub Jumpbox route')
module hubRouteJumpbox './modules/Microsoft.Network/routeTables/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-rt-jumpbox'
  params: {
    name: 'rt-${dplPrefix}-jumpbox'
    location: location
    tags: allTags
    routes: contains(hubConfig, 'networkRoutes') ? hubConfig.networkRoutes.jumpbox : {}
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

@description('routes for hub jumpbox subnet')
output route_jumpbox array = !hasRoutes ? [] : map(range(0, length(hubConfig.networkRoutes.jumpbox)), i => {
   name: contains(hubConfig.networkRoutes.jumpbox[i], 'name') ? hubConfig.networkRoutes.jumpbox[i].name : 'nsg_jumpbox${i}'
   properties: hubConfig.networkRoutes.jumpbox[i].properties
})

//------------------------------------------------------------------------------
// Process hub virtual network and subnets

// not yet working
//var enabledHubSubnets = union(map(filter(items(hubConfig.hubNetwork.subnets), arg => arg.value.enabled), arg => arg.value.name), [])

var txtHubConfig_base = loadTextContent('config/hub.jsonc')
var txtHubConfig_nsg_bastion = replace(txtHubConfig_base, '--nsg-bastion--', '${hubNSGbastion.outputs.resourceId}')
var txtHubConfig_nsg_jumpbox = replace(txtHubConfig_nsg_bastion, '--nsg-jumpbox--', '${hubNSGjumpbox.outputs.resourceId}')
var txtHubConfig_rt_jumpbox = replace(txtHubConfig_nsg_jumpbox, '--rt-jumpbox--', '${hubRouteJumpbox.outputs.resourceId}')

var transformedHubConfig = json(txtHubConfig_rt_jumpbox)
var hubSubnets = transformedHubConfig.hubNetwork.subnets.value

// above has to be rewritten - task - how to inject the nsg and rt ids into the config json object?
// did not find a function which would transform a json object back to a string (but it is already late :-)

@description('Deploy Hub virtual network incl. subnets')
module hubVnet './modules/Microsoft.Network/virtualNetworks/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-vnet'
  params: {
    addressPrefixes: contains(hubConfig, 'hubNetwork') ? hubConfig.hubNetwork.addressPrefixes.value : {}
    subnets: hubSubnets
    name: 'vn-${dplPrefix}-hub-01'
    location: location
    tags: allTags
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
    hubNSGbastion
    hubNSGjumpbox
    hubRouteJumpbox
  ]
}
