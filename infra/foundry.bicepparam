// Parameters for the vendored template-15 deployment (infra/foundry/main.bicep).
// scripts/deploy-infra.ps1 sets the environment variables read below.
using './foundry/main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param aiServices = readEnvironmentVariable('FOUNDRY_ACCOUNT_PREFIX', 'jnjm365fdy')
param firstProjectName = readEnvironmentVariable('FOUNDRY_PROJECT_PREFIX', 'm365agents')
param projectDescription = 'JNJ POC: private Foundry hosted agent published to Microsoft 365 Copilot and Teams'
param displayName = 'JNJ M365 Agents POC'

param modelName = 'gpt-5.4-mini'
param modelFormat = 'OpenAI'
param modelVersion = '2026-03-17'
param modelSkuName = 'GlobalStandard'
param modelCapacity = 30

// Bring the spoke VNet created by infra/network.bicep. Subnets already carry delegation,
// NSGs and the forced-tunnel route table, so the template must not rewrite them.
param existingVnetResourceId = readEnvironmentVariable('EXISTING_VNET_ID')
param agentSubnetName = 'agent-subnet'
param peSubnetName = 'pe-subnet'
param reuseExistingSubnets = true

// Hosted agents are deployed as source code, so no container registry is needed.
param enableContainerRegistry = false
param disableLocalAuth = true

// Optional BYO Azure AI Search (Learn: dependent resources may be in a different region than the VNet;
// the private endpoint is still created in the VNet region). Used in this POC because East US 2 was
// out of AI Search Standard capacity at deployment time.
param aiSearchResourceId = readEnvironmentVariable('AI_SEARCH_RESOURCE_ID', '')
