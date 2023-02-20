

Already Deployed: 

- Resource Groups
- NSGs, Routes
- VNet and Subnets
- Log Analytics Workspace
- Application Insights
- pip AzFirewall
- Azure Firewall
- pipBastion
- Azure Bastion
- VPN Gateway depoloyment

Currently Working On 

- VPN Gateway depoloyment


- How to configure (static) RT on VHUB towards the FW private IP? But only, if AzFW has to be deployed? - currently part of the .jsonc file


Known Issues:

- 'AzureAsyncOperationWaiting' errors when Bastion and FW are both set to false - only VPNG to true

Open

- private DNS Zone (link to Hub Vnet)
- Propagate diagonstic settings


- VM Jumpboxes: Win and Linux  (for Win: can we use a an image version which supports VTMP module?)
- VM Jumpbox: Can we apply a DSC config? -> allow RDP to Windows Images (in case we want to domain join them)

- Create a Spoke Network incl. subnets and peering to Hub + link to private DNS?


- Validate that default bicep parameters don't contradict secure deployment (e.g. for LogAnalytics ingestion)
- Review applicationRuleCollection in Azure Firewall
- Review networkRuleCollection for Spoke to Spoke connectivity

- Collect all relevant output for Secure Batch Repository (as input)

- Implement schema validation?
- GitHub Auto-Testing