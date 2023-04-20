//------------------------------------------------------------------------------
// Note: 
//
// The Hub + other relevant components are based on the Common Azure Resources Library
//
// Please find the full repo incl. documentation here: https://github.com/Azure/ResourceModules/
//------------------------------------------------------------------------------

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
param deployAzureFirewall bool =  true

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
param pdnsZoneConfigBase string = loadTextContent('config/privateDNSzone.json')

@description('Jumpbox Configuration settings')
param vmJumpBoxConfig object = loadJsonContent('config/jumpbox.jsonc')

@description('Load the init script of the Linux Jumpbox')
param vmJumpBoxLinuxInit string = loadTextContent('artefacts/linux-vm-init-script.sh')

@description('Load diagnostic settings')
param diagnosticConfig object = loadJsonContent('config/diagnostics.json')

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
    diagnosticMetricsToEnable: enabledMetricsCategories
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticLogsRetentionInDays: retentionDays
    enableDefaultTelemetry: false 
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
    enableDefaultTelemetry: false
    retentionInDays: 30
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

//------------------------------------------------------------------------------
// Process hub network network security groups


@description('Deploy Hub Bastion NSG')
module hubNSGbastion './modules/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-nsg-bastion'
  params: {
    name: 'nsg-${rsPrefix}-bastion'
    location: location
    tags: allTags
    securityRules: contains(hubConfig, 'networkSecurityGroups') ? hubConfig.networkSecurityGroups.bastion : {}
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
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
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

//------------------------------------------------------------------------------
// Process hub network route tables

@description('Deploy Hub Jumpbox route')
module hubRouteJumpbox './modules/Microsoft.Network/routeTables/deploy.bicep' = {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-hub-network-rt-jumpbox'
  params: {
    name: 'rt-${rsPrefix}-jumpbox'
    location: location
    tags: allTags
    routes: contains(hubConfig, 'networkRoutes') ? hubConfig.networkRoutes.jumpbox : {}
    enableDefaultTelemetry: false
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
  ]
}

//------------------------------------------------------------------------------
// Process hub virtual network and subnets

var txtHubConfig_base = loadTextContent('config/hub.jsonc')
var txtHubConfig_nsg_bastion = replace(txtHubConfig_base, '--nsg-bastion--', '${hubNSGbastion.outputs.resourceId}')
var txtHubConfig_nsg_jumpbox = replace(txtHubConfig_nsg_bastion, '--nsg-jumpbox--', '${hubNSGjumpbox.outputs.resourceId}')
var txtHubConfig_rt_jumpbox = replace(txtHubConfig_nsg_jumpbox, '--rt-jumpbox--', '${hubRouteJumpbox.outputs.resourceId}')

var transformedHubConfig = json(txtHubConfig_rt_jumpbox)
var hubSubnets = transformedHubConfig.hubNetwork.subnets.value


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
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticMetricsToEnable: enabledMetricsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
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
  
var pipAzFwAddressObject =  {
  name: 'pip-${rsPrefix}-azfw'
  publicIPAllocationMethod: hubConfig.publicIPSettings.publicIPAllocationMethod
  skuName: hubConfig.publicIPSettings.skuName
  skuTier: hubConfig.publicIPSettings.skuTier
}

@description('Deploy Azure Firewall service')
module azFirewall './modules/Microsoft.Network/azureFirewalls/deploy.bicep' = if (deployAzureFirewall) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-AzFirewall'
  params: {
    name: 'afw-${rsPrefix}'
    location: location
    tags: allTags
    publicIPAddressObject: pipAzFwAddressObject
    vNetId: hubVnet.outputs.resourceId
    applicationRuleCollections: azFwConfig.applicationRuleCollections.value
    networkRuleCollections: azFwConfig.networkRuleCollections.value
    zones:  hubConfig.publicIPSettings.zones
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticMetricsToEnable: enabledMetricsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
  }
  dependsOn: [
    // this is necessary to ensure all resource groups have been deployed
    // before we attempt to deploy resources under those resource groups.
    resourceGroups
    hubVnet
    logAnalyticsWorkspace
  ]
}

var pipAzBastionAddressObject =  {
  name: 'pip-${rsPrefix}-azbastion'
  publicIPAllocationMethod: hubConfig.publicIPSettings.publicIPAllocationMethod
  skuName: hubConfig.publicIPSettings.skuName
  skuTier: hubConfig.publicIPSettings.skuTier
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
    publicIPAddressObject: pipAzBastionAddressObject
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticLogCategoriesToEnable: enabledLogsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
  }
  dependsOn: [
    resourceGroups
    hubVnet
    logAnalyticsWorkspace
  ]
}

//------------------------------------------------------------------------------
// Deploy VPN Gateway Resources

@description('Deploy Azure VPN Gateway service')
module vpnGateway './modules/Microsoft.Network/virtualNetworkGateways/deploy.bicep' = if (deployVPNGateway) {
  scope: resourceGroup(resourceGroupNames.networkHubRG.name)
  name: '${dplPrefix}-vpnGateway'
  params: {
    name: 'vpngw-${rsPrefix}'
    location: location
    tags: allTags
    virtualNetworkGatewaySku:  vpngConfig.virtualNetworkGatewaySku
    virtualNetworkGatewayType:  vpngConfig.virtualNetworkGatewayType
    vNetResourceId: hubVnet.outputs.resourceId
    enableBgp:  vpngConfig.enableBgp
    vpnType:  vpngConfig.vpnType
    activeActive:  vpngConfig.activeActive
    gatewayPipName: 'pip-${rsPrefix}-vpngw'
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticMetricsToEnable: enabledMetricsCategories
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
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
    enableDefaultTelemetry: false
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
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
    
  } 
  dependsOn: [
    resourceGroups
    hubVnet
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
    enableDefaultTelemetry: false
    diagnosticLogsRetentionInDays: retentionDays
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.resourceId
    securityType: contains(vmJumpBoxConfig.windows,'securityType') ? vmJumpBoxConfig.windows.securityType : ''
    vTpmEnabled: contains(vmJumpBoxConfig.windows, 'vTpmEnabled') ? vmJumpBoxConfig.windows.vTpmEnabled : false
    secureBootEnabled: contains(vmJumpBoxConfig.windows, 'secureBootEnabled') ? vmJumpBoxConfig.windows.secureBootEnabled : false
  } 
  dependsOn: [
    resourceGroups
    hubVnet
  ]
}

//------------------------------------------------------------------------------
// Create the output for the "sister" repo to deploy Secure Azure Batch


@description('output azBatch-starter hub configuration values')
output azbatchStarter object = {
  
    diagnostics: {

      /// if "logAnalyticsWorkspace" is specified, diagnostic logs will be sent to the workspace.
      logAnalyticsWorkspace: {

          /// log analytics workspace id
          id: logAnalyticsWorkspace.outputs.resourceId
      }

      /// Application Insights is used to collect metrics and logs from the application.
      appInsights: {
          appId: appInsights.outputs.applicationId
          instrumentationKey: appInsights.outputs.instrumentationKey
      }
    }

    network: {

        /// user defined routes to use as first hop for the spoke vnets. This is useful for routing traffic to
        /// firewall, for example. Routes are specified as a list of objects in the `Route` format defined
        /// here: https://learn.microsoft.com/en-us/azure/templates/microsoft.network/routetables?tabs=bicep&pivots=deployment-language-bicep#route

      routes: [
        {
          name: 'r-nexthop-to-fw'
          properties: {
            nextHopType: 'VirtualAppliance'
            addressPrefix: '0.0.0.0/0'
            nextHopIpAddress: azFirewall.outputs.privateIp
          }
        }
      ]

      // "peerings" specifies vnet configurations to peer with.

      peerings: [
        {
          group: resourceGroupNames.networkHubRG.name 
          name: hubVnet.outputs.name
          useGateway: true
        }
      ]

      // "dnsZones" passes information about dns zones already created in the hub
      dnsZones: map(pdnsZoneConfig.privateDnsZones.value, zoneName => {
        group: resourceGroupNames.networkHubRG.name
        name: zoneName
      })
    }
} 
