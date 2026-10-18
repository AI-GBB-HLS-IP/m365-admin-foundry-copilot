/*
  Spoke network for the private Foundry hosted-agent POC.

  Deployed BEFORE the Foundry template (infra/foundry/main.bicep) so that the agent subnet
  already has its delegation, NSG and forced-tunnel route table when the Foundry account is
  created with network injection. The Foundry template is then run with
  existingVnetResourceId + reuseExistingSubnets=true so it never rewrites these subnets.

  Subnets (default 10.50.0.0/16):
    agent-subnet                   10.50.0.0/24   delegated to Microsoft.App/environments (hosted agents run here)
    pe-subnet                      10.50.1.0/24   private endpoints (Foundry, Search, Cosmos, Storage, AMPLS)
    jumpbox-subnet                 10.50.2.0/27   admin VM used for private data-plane operations
    AzureFirewallSubnet            10.50.3.0/26   Azure Firewall Basic (data plane)
    AzureFirewallManagementSubnet  10.50.3.64/26  Azure Firewall Basic (management plane, required by Basic)
    dns-inbound-subnet             10.50.3.160/28 DNS Private Resolver inbound endpoint (infra/vpn.bicep)

  infra/vpn.bicep adds a peered hub VNet (10.60.0.0/24) with the P2S VPN gateway. Re-run
  scripts/setup-vpn.ps1 after redeploying this template so the spoke peering is restored.
*/

@description('Azure region. Must match the Foundry account region.')
param location string = resourceGroup().location

@description('Short prefix used for resource names.')
param namePrefix string = 'jnjm365'

param vnetAddressPrefix string = '10.50.0.0/16'
param agentSubnetPrefix string = '10.50.0.0/24'
param peSubnetPrefix string = '10.50.1.0/24'
param jumpboxSubnetPrefix string = '10.50.2.0/27'
param firewallSubnetPrefix string = '10.50.3.0/26'
param firewallManagementSubnetPrefix string = '10.50.3.64/26'
param dnsInboundSubnetPrefix string = '10.50.3.160/28'

@description('FQDNs the hosted-agent subnet may reach over HTTPS. Everything else is denied by the firewall.')
param agentAllowedFqdns array = [
  // MCP tool used by the agent (Microsoft Learn MCP server)
  'learn.microsoft.com'
  // Microsoft Entra ID / managed identity token acquisition
  'login.microsoftonline.com'
  '*.login.microsoftonline.com'
  'login.microsoft.com'
  '*.login.microsoft.com'
  '*.identity.azure.net'
  // Hosted-agent runtime images and Container Apps platform dependencies
  'mcr.microsoft.com'
  '*.data.mcr.microsoft.com'
  'packages.aks.azure.com'
  'acs-mirror.azureedge.net'
  // Source-code deployment (remote_build installs Python dependencies)
  'pypi.org'
  'files.pythonhosted.org'
  // Agent 365 observability export used by the Foundry hosting libraries
  'agent365.svc.cloud.microsoft'
]

@description('Service tags the hosted-agent subnet may reach on TCP 443.')
param agentAllowedServiceTags array = [
  'AzureActiveDirectory'
  'MicrosoftContainerRegistry'
  'AzureFrontDoor.FirstParty'
]

@description('Admin username for the jumpbox.')
param jumpboxAdminUsername string = 'azureuser'

@description('SSH public key for the jumpbox. The VM has no public IP; it is operated with Run Command (or Bastion).')
@secure()
param jumpboxSshPublicKey string

param jumpboxVmSize string = 'Standard_D2s_v7'

param tags object = {}

var vnetName = 'vnet-${namePrefix}'
var firewallName = 'afw-${namePrefix}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}-net'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource agentNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-agent'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource peNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-jumpbox'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// The firewall private IP is the first usable address in AzureFirewallSubnet (x.x.x.4).
var firewallPrivateIp = cidrHost(firewallSubnetPrefix, 3)

resource egressRouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${namePrefix}-egress'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'agent-subnet'
        properties: {
          addressPrefix: agentSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: agentNsg.id
          }
          routeTable: {
            id: egressRouteTable.id
          }
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix: peSubnetPrefix
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: {
            id: peNsg.id
          }
        }
      }
      {
        name: 'jumpbox-subnet'
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: jumpboxNsg.id
          }
          routeTable: {
            id: egressRouteTable.id
          }
        }
      }
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallSubnetPrefix
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: firewallManagementSubnetPrefix
        }
      }
      // Developer access (infra/vpn.bicep): DNS Private Resolver inbound endpoint. The P2S VPN
      // gateway itself lives in a peered hub VNet.
      {
        name: 'dns-inbound-subnet'
        properties: {
          addressPrefix: dnsInboundSubnetPrefix
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'Microsoft.Network.dnsResolvers'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource firewallDataPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namePrefix}-afw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallMgmtPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namePrefix}-afw-mgmt'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: 'afwp-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Basic'
    }
    threatIntelMode: 'Alert'
  }
}

resource agentEgressRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: firewallPolicy
  name: 'agent-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'agent-platform-service-tags'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'agent-to-platform-tags'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: [
              agentSubnetPrefix
            ]
            destinationAddresses: agentAllowedServiceTags
            destinationPorts: [
              '443'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'agent-approved-fqdns'
        priority: 200
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'agent-to-approved-fqdns'
            sourceAddresses: [
              agentSubnetPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: agentAllowedFqdns
          }
        ]
      }
    ]
  }
}

// The jumpbox is an admin workstation: it installs tooling (az, azd, Python) and therefore gets
// broad web egress. In production, replace with a hardened, managed admin host or a CI/CD agent.
resource jumpboxEgressRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: firewallPolicy
  name: 'jumpbox-egress'
  properties: {
    priority: 300
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'jumpbox-web'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'jumpbox-to-web'
            sourceAddresses: [
              jumpboxSubnetPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
              {
                protocolType: 'Http'
                port: 80
              }
            ]
            targetFqdns: [
              '*'
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [
    agentEgressRules
  ]
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: firewallName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'data'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/AzureFirewallSubnet'
          }
          publicIPAddress: {
            id: firewallDataPip.id
          }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'management'
      properties: {
        subnet: {
          id: '${vnet.id}/subnets/AzureFirewallManagementSubnet'
        }
        publicIPAddress: {
          id: firewallMgmtPip.id
        }
      }
    }
  }
  dependsOn: [
    agentEgressRules
    jumpboxEgressRules
  ]
}

resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: firewall
  properties: {
    workspaceId: logAnalytics.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource jumpboxNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${namePrefix}-jumpbox'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/jumpbox-subnet'
          }
        }
      }
    ]
  }
}

resource jumpbox 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-${namePrefix}-jumpbox'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: jumpboxVmSize
    }
    osProfile: {
      computerName: 'jumpbox'
      adminUsername: jumpboxAdminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${jumpboxAdminUsername}/.ssh/authorized_keys'
              keyData: jumpboxSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      diskControllerType: 'NVMe'
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jumpboxNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
  // Egress for package installs flows through the firewall.
  dependsOn: [
    firewall
  ]
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output agentSubnetName string = 'agent-subnet'
output peSubnetName string = 'pe-subnet'
output firewallName string = firewall.name
output firewallPrivateIp string = firewallPrivateIp
output firewallPublicIp string = firewallDataPip.properties.ipAddress
output logAnalyticsWorkspaceId string = logAnalytics.id
output jumpboxName string = jumpbox.name
output jumpboxPrincipalId string = jumpbox.identity.principalId
