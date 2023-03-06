

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
- Create public IP for VPN Gateway (like for AzFW and Bastion, so we can have the same naming convention) - done?
- private DNS Zone (link to Hub Vnet)
- Linux VM Jumpbox
- Windows VM Jumpbox

Currently Working On 

- Initial Cleanup
- VM Jumpboxes: Win (for Win: can we use a an image version which supports VTMP module?)
- How to configure (static) RT on VHUB towards the FW private IP? But only, if AzFW has to be deployed? - currently part of the .jsonc file


Known Issues:

- Custom Script for Linux Jumpbox not executed? -> possibly wrong datatype for custom data (string expected, not base64) -> solved.

- 'AzureAsyncOperationWaiting' errors when Bastion and FW are both set to false - only VPNG to true

- if AzFW true and Bastion True, but VPNGW false -> concurracy issue on Gateway Subnet -> error. Not clear, what causes the concurracy race: stopped after both (L,W) Jumpboxes were commented out.... added azFw and azBastion to dependencies

-> might be related to LibModule for VNets -> added batchsize(1) annotation to force the for loop to execute 1 subnet at the time
-> file PR for custom extension: CodeToExecute was not part of the final parameter set.


Open

- Verify if Workspace ID is enabled on all resources
- Propagate diagonstic settings

- VM Jumpbox: Can we apply a DSC config? -> allow RDP to Windows Images (in case we want to domain join them)

- Create a Spoke Network incl. subnets and peering to Hub + link to private DNS? (AzBatch side)

- Validate that default bicep parameters don't contradict secure deployment (e.g. for LogAnalytics ingestion)
- Review applicationRuleCollection in Azure Firewall
- Review networkRuleCollection for Spoke to Spoke connectivity

- Collect all relevant output for Secure Batch Repository (as input)

- Implement schema validation?
- GitHub Auto-Testing