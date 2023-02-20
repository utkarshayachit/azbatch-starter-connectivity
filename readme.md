

Already Deployed: 

- Resource Groups
- NSGs, Routes
- VNet and Subnets
- Log Analytics Workspace
- Application Insights
- pip AzFirewall
- Azure Firewall
- pipBastion

Currently Working On 

- Azure Bastion

- How to configure (static) RT on VHUB towards the FW private IP? But only, if AzFW has to be deployed? - currently part of the .jsonc file

Open

- Propagate diagonstic settings
- VPN Gateway depoloyment
- private DNS Zone (link to Hub Vnet)
- VM Jumpboxes: Win and Linux

- Create a Spoke Network incl. subnets and peering to Hub + link to private DNS?


- Validate that default bicep parameters don't contradict secure deployment (e.g. for LogAnalytics ingestion)
- Review applicationRuleCollection in Azure Firewall
- Review networkRuleCollection for Spoke to Spoke connectivity

- Collect all relevant output for Secure Batch Repository (as input)

- Implement schema validation?
- GitHub Auto-Testing