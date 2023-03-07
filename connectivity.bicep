// https://github.com/Azure/ResourceModules/

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

@description('Log Analytics Service Tier: PerGB2018, Free, Standalone, PerGB or PerNode.')
@allowed([
  'Free'
  'Standalone'
  'PerNode'
  'PerGB2018'
])
param logAnalyticsServiceTier string = 'PerGB2018'

@description('when true, an Azure Firewall will be deployed')
param deployAzureFirewall bool = true

@description('when true, an Azure Bastion will be deployed')
param deployAzureBastion bool = true

@description('when true, a VPN Gateway will be deployed')
param deployVPNGateway bool = true

@description('when true, a Linux VM will be deployed into the Hub Network')
param deployLinuxJumpbox bool = true

@description('when true, a Windows VM will be deployed into the Hub Network')
param deployWindowsJumpbox bool = true

@description('deployment timestamp')
param timestamp string = utcNow('g')

@secure()
param adminPassword string 

//------------------------------------------------------------------------------
// Load exteranl configuration objects
//------------------------------------------------------------------------------

@description('hub configuration')
param hubConfig object = loadJsonContent('config/hub.jsonc')

@description('Azure Firewall Configuration')
param azFwConfig object = loadJsonContent('config/azFirewall.jsonc')

@description('Azure VPN Gateway Configuration')
param vpngConfig object = loadJsonContent('config/vpnGateway.jsonc')

@description('Private DNS Zone Configuration')
param pdnsZoneConfigBase string = loadTextContent('config/privateDnszone.json')

@description('Jumpbox Configuration settings')
param vmJumpBoxConfig object = loadJsonContent('config/jumpbox.jsonc')

@description('Load the init script of the Linux Jumpbox')
param vmJumpBoxLinuxInit string = loadTextContent('artefacts/linux-vm-init-script.sh')

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
    name: 'log-${rsPrefix}'
    location: location
    tags: allTags
    serviceTier: logAnalyticsServiceTier
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
    name: 'appi-${rsPrefix}'
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

var hasNsg = contains(hubConfig, 'networkSecurityGroups') && length(hubConfig.networkSecurityGroups) > 0

@description('Deploy Hub Bastion NSG')
module hubNSGbastion './modules/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-nsg-bastion'
  params: {
    name: 'nsg-${rsPrefix}-bastion'
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

@description('Deploy Jumpbox NSG')
module hubNSGjumpbox './modules/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-nsg-jumpbox'
  params: {
    name: 'nsg-${rsPrefix}-jumpbox'
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

//------------------------------------------------------------------------------
// Process hub network route tables

var hasRoutes = contains(hubConfig, 'networkRoutes') && length(hubConfig.networkRoutes) > 0

@description('Deploy Hub Jumpbox route')
module hubRouteJumpbox './modules/Microsoft.Network/routeTables/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-rt-jumpbox'
  params: {
    name: 'rt-${rsPrefix}-jumpbox'
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
    name: 'vn-${rsPrefix}-hub-01'
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

//------------------------------------------------------------------------------
// Deploy Azure Firewall Resources

@description('Deploy a public IP for Azure Firewall')
module pipAzFirewall './modules/Microsoft.Network/publicIPAddresses/deploy.bicep' = if (deployAzureFirewall) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-pipAzFirewall'
  params: {
    name: 'pip-${rsPrefix}-azfw'
    location: location
    tags: allTags
    skuName: azFwConfig.publicIPSettings.skuName
    publicIPAllocationMethod: azFwConfig.publicIPSettings.publicIPAllocationMethod
    zones: azFwConfig.publicIPSettings.zones
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}
  
@description('Deploy Azure Firewall service')
module azFirewall './modules/Microsoft.Network/azureFirewalls/deploy.bicep' = if (deployAzureFirewall) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-AzFirewall'
  params: {
    name: 'afw-${rsPrefix}'
    location: location
    tags: allTags
    azureFirewallSubnetPublicIpId: pipAzFirewall.outputs.resourceId
    vNetId: hubVnet.outputs.resourceId
    applicationRuleCollections: azFwConfig.applicationRuleCollections.value
    networkRuleCollections: azFwConfig.networkRuleCollections.value
    enableDefaultTelemetry: true
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
    hubVnet
    pipAzFirewall
    logAnalyticsWorkspace
  ]
}

//------------------------------------------------------------------------------
// Deploy Azure Bastion Resources

@description('Deploy a public IP for Azure Bastion')
module pipAzBastion './modules/Microsoft.Network/publicIPAddresses/deploy.bicep' = if (deployAzureBastion) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-pipAzBastion'
  params: {
    name: 'pip-${rsPrefix}-azbastion'
    location: location
    tags: allTags
    skuName: azFwConfig.publicIPSettings.skuName
    publicIPAllocationMethod: azFwConfig.publicIPSettings.publicIPAllocationMethod
    zones: azFwConfig.publicIPSettings.zones
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

@description('Deploy Azure Bastion service')
module azBastion './modules/Microsoft.Network/bastionHosts/deploy.bicep' = if (deployAzureBastion) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-AzBastion'
  params: {
    name: 'bas-${rsPrefix}'
    location: location
    tags: allTags
    vNetId: hubVnet.outputs.resourceId
    azureBastionSubnetPublicIpId: pipAzBastion.outputs.resourceId
    enableDefaultTelemetry: true
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
  }
  dependsOn: [
    resourceGroups
    pipAzBastion
    hubVnet
    logAnalyticsWorkspace
    azFirewall
  ]
}

//------------------------------------------------------------------------------
// Deploy VPN Gateway Resources

@description('Deploy Azure VPN Gateway service')
module vpnGateway './modules/Microsoft.Network/virtualNetworkGateways/deploy.bicep' = if (deployVPNGateway) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-vpnGateway'
  params: {
    name: 'vpng-${rsPrefix}'
    location: location
    tags: allTags
    virtualNetworkGatewaySku:  vpngConfig.virtualNetworkGatewaySku
    virtualNetworkGatewayType:  vpngConfig.virtualNetworkGatewayType
    vNetResourceId: hubVnet.outputs.resourceId
    enableBgp:  vpngConfig.enableBgp
    enableDefaultTelemetry: true
    vpnType:  vpngConfig.vpnType
    activeActive:  vpngConfig.activeActive
    gatewayPipName: 'pip-${rsPrefix}-vpngw'  
  }
  dependsOn: [
    resourceGroups
    hubVnet
  ]
}

//------------------------------------------------------------------------------
// Deploy private DNS Zones Resources

// Replace region specific dns zone entries with the deployment region
var  pdnsZoneConfig = json(replace(pdnsZoneConfigBase, 'xxxxxx', location))

var virtualNetworkLinks = [
  {
    registrationEnabled: false
    virtualNetworkResourceId: hubVnet.outputs.resourceId
  }
]

@description('Deploy private Dns Zones for private endpoint resolution')
module privateDnsZone './modules/Microsoft.Network/privateDnsZones/deploy.bicep' = [for dnsZone in pdnsZoneConfig.privateDnsZones.value: {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-pdnsz-${dnsZone}'
  params: {
    name: dnsZone
    location: 'global'
    tags: allTags
    enableDefaultTelemetry: true
    virtualNetworkLinks: virtualNetworkLinks
  }
  dependsOn: [
    resourceGroups
    hubVnet
  ]
}]
 
//------------------------------------------------------------------------------
// Deploy private Hub Jumpboxes

var jumpboxSubNetId = '${hubVnet.outputs.resourceId}/subnets/${vmJumpBoxConfig.linux.vmSubnet}'

var nicConfigurations = {
  linux: [
    {
      nicSuffix: '-nic-linux'
      enableAcceleratedNetworking: vmJumpBoxConfig.linux.enableAcceleratedNetworking
      ipConfigurations: [
        {
          name: 'ipconfig-linux'
          subnetResourceId: jumpboxSubNetId
          privateIPAllocationMethod: 'Dynamic'
        }
      ]
    }
  ]
  windows: [
    {
      nicSuffix: '-nic-windows'
      enableAcceleratedNetworking: vmJumpBoxConfig.linux.enableAcceleratedNetworking
      ipConfigurations: [
        {
          name: 'ipconfig-windows'
          subnetResourceId: jumpboxSubNetId
          privateIPAllocationMethod: 'Dynamic'
        }
      ]
    }
  ]
} 

@description('deploy a Linux VM into the Hub network')
module linuxJumpBox './modules/Microsoft.Compute/virtualMachines/deploy.bicep' = if (deployLinuxJumpbox) { 
  scope: resourceGroup(resourceGroupNames.connectivityJumpBoxRG.name)
  name: '${dplPrefix}-vm-linux-jumpbox'
  params: {
    location: location
    tags: allTags
    name: '${rsPrefix}-${vmJumpBoxConfig.linux.vmNameSuffix}'
    imageReference: vmJumpBoxConfig.linux.imageReference.value
    nicConfigurations: nicConfigurations.linux
    osDisk: vmJumpBoxConfig.linux.osDisk.value
    osType: vmJumpBoxConfig.linux.osType
    vmSize: vmJumpBoxConfig.linux.vmSize
    encryptionAtHost: vmJumpBoxConfig.linux.encryptionAtHost
    customData: vmJumpBoxLinuxInit
    adminUsername: vmJumpBoxConfig.linux.adminUsername
    adminPassword: adminPassword
  } 
  dependsOn: [
    resourceGroups
    hubVnet
    hubNSGjumpbox
    azFirewall
    azBastion
    privateDnsZone
    vpnGateway
  ]
}

var extensionCustomScriptConfig =  {
  enabled: vmJumpBoxConfig.windows.deployJumpboxAddOns
  fileData: [ 
    {
    uri: vmJumpBoxConfig.windows.vmExtensionWindowsJumpboxUri
    }
  ]
  settings: {
    commandToExecute: vmJumpBoxConfig.windows.vmExtensionCommandToExecute
  }
}


@description('deploy a Windows VM into the Hub network')
module windowsJumpBox './modules/Microsoft.Compute/virtualMachines/deploy.bicep' = if (deployWindowsJumpbox) { 
  scope: resourceGroup(resourceGroupNames.connectivityJumpBoxRG.name)
  name: '${dplPrefix}-vm-windows-jumpbox'
  params: {
    location: location
    tags: allTags
    name: vmJumpBoxConfig.windows.vmName
    imageReference: vmJumpBoxConfig.windows.imageReference.value
    nicConfigurations: nicConfigurations.windows
    osDisk: vmJumpBoxConfig.windows.osDisk.value
    osType: vmJumpBoxConfig.windows.osType
    vmSize: vmJumpBoxConfig.windows.vmSize
    encryptionAtHost: vmJumpBoxConfig.windows.encryptionAtHost
    extensionCustomScriptConfig: extensionCustomScriptConfig
    adminUsername: vmJumpBoxConfig.windows.adminUsername
    adminPassword: adminPassword
  } 
  dependsOn: [
    resourceGroups
    hubVnet
    hubNSGjumpbox
    azFirewall
    azBastion
    privateDnsZone
    vpnGateway
    linuxJumpBox
  ]
}



//------------------------------------------------------------------------------
// Output relevant values for the spoke network configuration

@description('Output Spoke Network Configuration values')
output hubInformation object = {
  workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
  appInsightsApplicationId: appInsights.outputs.applicationId
  hubVnetResourceId: hubVnet.outputs.resourceId
  fwPrivateIp: azFirewall.outputs.privateIp
}





