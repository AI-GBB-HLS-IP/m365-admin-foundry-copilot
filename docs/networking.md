# How this works: networking

This POC runs a Microsoft Foundry hosted agent in a fully private Azure environment and publishes it to Microsoft 365 Copilot and Teams. The publish path uses the Foundry-managed, **source-IP-filtered Activity Protocol route** (`enable_m365_public_endpoint`). That route is the only path that Microsoft 365 can call; every other Foundry API remains private.

## Architecture

```mermaid
flowchart LR
  subgraph M365["Microsoft 365 (Microsoft cloud)"]
    U["User in Teams / M365 Copilot"] --> CH["Teams / Copilot channel adapters"]
    CH --> BOT["Azure Bot Service<br/>(bot resource: PNA disabled, Teams channel)"]
  end

  subgraph FOUNDRY_EDGE["Foundry service edge"]
    AP["Activity Protocol route<br/>/agents/{name}/endpoint/protocols/activityProtocol<br/>source-IP filter + token + BotServiceTenant"]
  end

  BOT -- "HTTPS (public, Bot Service / M365 source ranges only)" --> AP

  subgraph SPOKE["Customer VNet 10.50.0.0/16 (East US 2)"]
    direction TB
    subgraph AGENT["agent-subnet 10.50.0.0/24<br/>delegated: Microsoft.App/environments"]
      HA["Hosted agent container<br/>(Agent Framework, Responses protocol)"]
    end
    subgraph PE["pe-subnet 10.50.1.0/24"]
      PEF["PE: Foundry account<br/>(services.ai / openai / cognitiveservices)"]
      PED["PE: Cosmos DB / AI Search / Storage"]
      PEM["PE: Azure Monitor (AMPLS)"]
    end
    subgraph JB["jumpbox-subnet 10.50.2.0/27"]
      VM["Jumpbox VM (no public IP)<br/>operated via Run Command"]
    end
    subgraph FW["AzureFirewallSubnet 10.50.3.0/26"]
      AFW["Azure Firewall Basic<br/>FQDN allow-list"]
    end
  end

  AP --> HA
  HA -- "model + toolbox MCP" --> PEF
  HA -- "threads, files, vectors" --> PED
  HA -- "traces" --> PEM
  HA -- "UDR 0.0.0.0/0" --> AFW
  VM -- "azd deploy / publish REST" --> PEF
  VM -- "UDR 0.0.0.0/0" --> AFW
  AFW -- "learn.microsoft.com, Entra, mcr, pypi" --> NET(("Internet"))
  NET --> MCP["Microsoft Learn MCP server<br/>learn.microsoft.com/api/mcp"]
```

## Address plan

| Subnet | CIDR | Purpose |
|---|---|---|
| `agent-subnet` | `10.50.0.0/24` | Delegated to `Microsoft.App/environments`. Foundry injects hosted-agent compute and capability-host traffic here. One Foundry account per subnet. |
| `pe-subnet` | `10.50.1.0/24` | Private endpoints for Foundry, Cosmos DB, AI Search, Storage, and Azure Monitor Private Link Scope. |
| `jumpbox-subnet` | `10.50.2.0/27` | Admin VM used for data-plane operations because the Foundry project rejects public callers. |
| `AzureFirewallSubnet` | `10.50.3.0/26` | Azure Firewall Basic data plane. Private IP `10.50.3.4` is the next hop for `0.0.0.0/0`. |
| `AzureFirewallManagementSubnet` | `10.50.3.64/26` | Required by Azure Firewall Basic for its management traffic. |

All subnets set `defaultOutboundAccess: false`, so internet egress is available only through the firewall route.

## Traffic flows

### 1. Teams / Microsoft 365 Copilot → agent (inbound)

1. The user sends a message in Teams or Microsoft 365 Copilot.
2. The channel adapter forwards it to the Azure Bot Service resource. Its messaging endpoint is the agent's Activity Protocol URL.
3. Bot Service calls `https://<account>.services.ai.azure.com/api/projects/<project>/agents/<agent>/endpoint/protocols/activityProtocol` over the public internet.
4. The Foundry edge accepts the request **only** if all of the following checks pass:
   - **Source IP:** The request originates from Azure Bot Service or Microsoft 365 source ranges. Foundry determines the IP at its edge, so forwarding headers can't spoof it, and it denies requests without a source IP.
   - **Token:** The signed Bot Framework channel token is valid for the agent's identity.
   - **Authorization scheme:** `BotServiceTenant` requires the caller to be in this tenant. `BotServiceRbac` also requires Foundry RBAC on the project.
5. Foundry routes the authorized activity to the active agent version that runs in `agent-subnet`.

No public IP, DNAT, load balancer, certificate, or inbound firewall rule exists in the customer VNet. The Activity route is a service-managed exception. Microsoft 365 doesn't support Private Link, so this is the documented way to reach a private-network agent from Microsoft 365.

### 2. Agent → model, toolbox, and state (private)

| Destination | Path |
|---|---|
| Model (`gpt-5.4-mini`) | Private endpoint in `pe-subnet` |
| Foundry Toolbox MCP endpoint (`/toolboxes/learn-tools/mcp`) | Private endpoint in `pe-subnet` |
| Threads (Cosmos DB), files (Storage), vectors (AI Search) | Private endpoints. These BYO resources provide the Standard Agent Setup data plane. |
| Traces (Application Insights) | Azure Monitor Private Link Scope private endpoint |

> **Deployment note:** East US 2 had no Azure AI Search Standard capacity during deployment, so the POC uses a BYO Search service in **Central US** (`jnjm365srchcus`) with public network access disabled. Its private endpoint remains in the East US 2 `pe-subnet` (`10.50.1.9`). Learn allows dependent resources to be in a different region from the VNet; only the Foundry account must match the VNet region.

Private DNS zones (`privatelink.services.ai.azure.com`, `privatelink.openai.azure.com`, `privatelink.documents.azure.com`, and others) are linked to the VNet, so the same public FQDNs resolve to `10.50.1.x` inside the network.

### 3. Agent → MCP server (governed egress)

Toolbox MCP tool traffic flows through the project's delegated subnet ([toolbox network isolation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/toolbox-network-isolation)). The route table sends it to Azure Firewall, where an application rule allows only these destinations:

| Purpose | Allowed FQDNs or service tags |
|---|---|
| MCP tool | `learn.microsoft.com` |
| Identity | `login.microsoftonline.com`, `*.login.microsoftonline.com`, `login.microsoft.com`, `*.login.microsoft.com`, `*.identity.azure.net`, and the `AzureActiveDirectory` service tag |
| Hosted-agent runtime and source-code deployment | `mcr.microsoft.com`, `*.data.mcr.microsoft.com`, `packages.aks.azure.com`, `acs-mirror.azureedge.net`, `pypi.org`, `files.pythonhosted.org`, and the `MicrosoftContainerRegistry` and `AzureFrontDoor.FirstParty` service tags |
| Agent 365 observability | `agent365.svc.cloud.microsoft` |

The firewall denies everything else. Firewall logs go to `log-jnjm365-net`, so security teams can see each allowed or denied call:

```kusto
AZFWApplicationRule
| where TimeGenerated > ago(1h)
| project TimeGenerated, SourceIp, Fqdn, Action, Rule, RuleCollection
| order by TimeGenerated desc
```

Adding a tool is therefore a two-part change: a toolbox change in Foundry and a firewall allow-list change owned by the network team.

Observed in this POC after one agent invocation:

| Source (agent-subnet) | Action | Destination | Rule |
|---|---|---|---|
| `10.50.0.111` | Allow | `learn.microsoft.com` | `agent-to-approved-fqdns` (MCP tool call) |
| `10.50.0.234` | Allow | `agent365.svc.cloud.microsoft` | `agent-to-approved-fqdns` (observability) |
| `10.50.0.197` | Allow | Entra ID IPs | `agent-to-platform-tags` (token acquisition) |
| `10.50.0.234` | **Deny** | `settings.sdk.monitor.azure.com` | Not allow-listed. Telemetry still flows privately through AMPLS. |

### 4. Builders and admins → Foundry (management vs. data plane)

| Plane | Example | Reachable from |
|---|---|---|
| ARM management (`management.azure.com`) | Create accounts, Bot Service, role assignments | Anywhere with Azure RBAC |
| Foundry data plane (`*.services.ai.azure.com`) | Create agent versions, toolboxes, invoke, publish | **Only** the VNet: jumpbox in this POC; ExpressRoute, VPN, or an in-VNet CI/CD runner at JNJ |

The POC operates the jumpbox through **Azure Run Command**, which uses the management plane. Therefore, the VM has no public IP and no inbound NSG rules. Bastion is optional.

### 5. Developer laptop → Foundry portal (P2S VPN)

The Foundry portal (`ai.azure.com`) is a public web app. Your **browser** calls the project data plane directly, so the browser must reach the private endpoint. `infra/vpn.bicep` (`./scripts/setup-vpn.ps1`) adds a small **hub-spoke** access layer:

| Component | Detail |
|---|---|
| Hub VNet `vnet-jnjm365-hub` `10.60.0.0/24` (Central US) | Contains `GatewaySubnet` `10.60.0.0/27` with VPN Gateway `VpnGw1AZ` (point-to-site OpenVPN). It peers with the spoke through **gateway transit**, so clients receive `172.16.201.0/24` and a route to the spoke `10.50.0.0/16`. The gateway runs in a separate hub region because zone-redundant gateway builds repeatedly failed in East US 2 for this subscription. |
| Microsoft Entra ID authentication | Uses the Microsoft-registered Azure VPN Client app (`c632b3df-fb67-4d84-bdcf-b95ad541b5c8`), so you don't need an app registration or certificates. Entra Conditional Access applies at sign-in. |
| `dns-inbound-subnet` `10.50.3.160/28` (spoke) | Azure DNS Private Resolver inbound endpoint. The client profile adds NRPT rules so names under `.services.ai.azure.com`, `.openai.azure.com`, `.cognitiveservices.azure.com`, `.search.windows.net`, `.documents.azure.com`, and `.blob.core.windows.net` resolve through the VNet's private DNS zones. |

Split tunneling is the default: only VNet traffic and DNS for those suffixes use the tunnel. At JNJ, ExpressRoute and the hub's DNS Private Resolver or conditional forwarders provide this access path. See [jnj-landing-zone.md](jnj-landing-zone.md).

## Public vs. private

| Endpoint | Exposure |
|---|---|
| Foundry account and project APIs (agents, responses, toolboxes, files) | **Private.** `publicNetworkAccess: Disabled`; public callers receive 403. |
| Activity Protocol route for the published agent | **Public, filtered.** Only Bot Service and Microsoft 365 source ranges with a valid token and authorization scheme can call it. |
| Cosmos DB, AI Search, Storage | **Private.** Public network access is disabled. |
| Application Insights ingestion | **Private** through AMPLS. |
| Azure Bot Service resource | Microsoft-managed. `publicNetworkAccess: Disabled`; only the Teams channel is enabled. |
| Hosted-agent egress | **Firewall allow-list** only |

## Verify it yourself

```powershell
./scripts/verify-network.ps1
```

The script confirms the following:

- `publicNetworkAccess` is `Disabled` on Foundry, Cosmos DB, AI Search, and Storage.
- A call from the internet to the project API is rejected.
- From inside the VNet, every service FQDN resolves to a `10.50.1.x` private IP, and the project API returns 401 (reachable, authentication required).
- Jumpbox egress leaves through the firewall's public IP.

## References

- [Publish agents to Microsoft 365 and Teams by using the REST API](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network), including the network-path details in Step 5
- [Set up private networking for Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks)
- [Standard agent setup](https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup)
- [Network isolation for a toolbox](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/toolbox-network-isolation)
- [Deploy a hosted agent from source code: firewall requirements](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent-code#firewall-requirements-for-private-virtual-networks)
