/*
  Developer access to the private Foundry data plane (Foundry portal, SDK, azd) from a laptop,
  using a hub-spoke layout:

    Hub VNet (gatewayLocation, default centralus) 10.60.0.0/24
      GatewaySubnet 10.60.0.0/27 -> P2S VPN Gateway (OpenVPN + Microsoft Entra ID auth with the
                                     Microsoft-registered Azure VPN Client app)
    Peering hub <-> spoke with gateway transit, so VPN clients get routes to the spoke 10.50.0.0/16.

    Spoke VNet (existing, Foundry region)
      dns-inbound-subnet 10.50.3.160/28 -> Azure DNS Private Resolver inbound endpoint, so clients
                                           resolve *.services.ai.azure.com etc. to private endpoint
                                           IPs (the client profile adds NRPT rules for those suffixes).

  The gateway lives in a separate hub region because zone-redundant gateway deployments repeatedly
  failed in East US 2 for this subscription. This also mirrors JNJ's hub-spoke topology, where the
  hub carries ExpressRoute/VPN and spokes host workloads.
*/
param location string = resourceGroup().location
param namePrefix string = 'jnjm365'
param spokeVnetName string = 'vnet-${namePrefix}'

param gatewayLocation string = 'centralus'
param hubVnetAddressPrefix string = '10.60.0.0/24'
param gatewaySubnetPrefix string = '10.60.0.0/27'
param dnsInboundSubnetPrefix string = '10.50.3.160/28'

@description('Address pool handed to VPN clients. Must not overlap the VNets or the client\'s local networks.')
param vpnClientAddressPool string = '172.16.201.0/24'

param tenantId string = subscription().tenantId

@description('Microsoft-registered Azure VPN Client app ID (no app registration or consent needed).')
param aadAudience string = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'

@allowed([
  'VpnGw1AZ'
  'VpnGw2AZ'
  'VpnGw3AZ'
])
param gatewaySku string = 'VpnGw1AZ'

@allowed([
  'Generation1'
  'Generation2'
])
param gatewayGeneration string = 'Generation1'

param tags object = {}

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: spokeVnetName
}

resource dnsInboundSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: spokeVnet
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

resource dnsResolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: 'dnspr-${namePrefix}'
  location: location
  tags: tags
  properties: {
    virtualNetwork: {
      id: spokeVnet.id
    }
  }
}

resource dnsInbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: dnsResolver
  name: 'inbound'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Dynamic'
        subnet: {
          id: dnsInboundSubnet.id
        }
      }
    ]
  }
}

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namePrefix}-hub'
  location: gatewayLocation
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubVnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
    ]
  }
}

resource gatewayPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namePrefix}-hub-vpngw'
  location: gatewayLocation
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: 'vpngw-${namePrefix}-hub'
  location: gatewayLocation
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: gatewayGeneration
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    enableBgp: false
    activeActive: false
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${hubVnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: gatewayPip.id
          }
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: {
        addressPrefixes: [
          vpnClientAddressPool
        ]
      }
      vpnClientProtocols: [
        'OpenVPN'
      ]
      vpnAuthenticationTypes: [
        'AAD'
      ]
      aadTenant: '${environment().authentication.loginEndpoint}${tenantId}/'
      aadAudience: aadAudience
      aadIssuer: 'https://sts.windows.net/${tenantId}/'
    }
  }
}

// Gateway transit: the hub shares its gateway; the spoke uses it. The spoke-side peering needs
// the gateway to exist first.
resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hubVnet
  name: 'hub-to-spoke'
  properties: {
    remoteVirtualNetwork: {
      id: spokeVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
  dependsOn: [
    vpnGateway
  ]
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: spokeVnet
  name: 'spoke-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
  dependsOn: [
    hubToSpoke
  ]
}

output vpnGatewayName string = vpnGateway.name
output dnsResolverInboundIp string = dnsInbound.properties.ipConfigurations[0].privateIpAddress
output vpnClientAddressPool string = vpnClientAddressPool
