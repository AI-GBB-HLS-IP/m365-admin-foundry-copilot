# How this fits into JNJ's environment

The POC is self-contained so it can run in a demo subscription. Each component maps directly to a standard Azure Landing Zone and Microsoft 365 operating model. This guide explains what changes when JNJ adopts the pattern, who owns each piece, and which decisions must be made first.

## POC → JNJ landing zone mapping

| POC component | In JNJ's environment |
|---|---|
| Standalone VNet `10.50.0.0/16` | An **application landing zone spoke** peered to the regional **connectivity hub**. Request a non-overlapping range from JNJ IPAM. The agent subnet needs a `/24` delegated to `Microsoft.App/environments` (dedicated to one Foundry account) and must avoid the [reserved ranges](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks#limitations). |
| Azure Firewall Basic in the spoke | Remove it. Point the agent subnet UDR (`0.0.0.0/0`) to the **hub firewall or NVA**. Add the FQDN allow-list in [networking.md](networking.md#3-agent--mcp-server-governed-egress) as a rule collection scoped to the agent subnet. **Don't apply TLS inspection** to these flows; Foundry's documentation calls out self-signed inspection certificates as a failure cause. |
| Private DNS zones created in the resource group | Use JNJ's **central private DNS zones** in the connectivity subscription. Template 15 supports this with `existingDnsZones` and `dnsZonesSubscriptionId`. If JNJ uses DNS policy, let DINE policies create the A records. Make sure on-premises resolvers forward to the Azure DNS Private Resolver for `privatelink.services.ai.azure.com`, `privatelink.openai.azure.com`, `privatelink.cognitiveservices.azure.com`, `privatelink.search.windows.net`, `privatelink.documents.azure.com`, `privatelink.blob.core.windows.net`, and the Azure Monitor zones. |
| Jumpbox and Run Command | Developers reach the private Foundry data plane over **ExpressRoute or VPN**. Pipelines use **self-hosted GitHub Actions runners or Azure DevOps agents in a spoke** with managed identity, running the same `azd deploy` used in `scripts/jumpbox/deploy-agent.sh`. Keep a hardened jump host only as a break-glass path. |
| Signed-in admin token for publishing | Run the four REST publish steps from the same in-VNet pipeline with a workload identity that has Foundry User and Azure Bot Service Contributor permissions. Keep tenant-scope approval human. |
| `sg-jnj-azure-advisor-pilot` | Use JNJ Entra groups, ideally governed by **access packages** with approval and expiry. These groups become the audience in the M365 admin center and Teams admin center. |
| Single subscription and resource group | Use separate **dev / test / prod** Foundry accounts or projects in landing zone subscriptions. Promote agents by deploying the same code and toolbox definition to each environment. Publish to M365 only from prod. |

## The one architectural exception to approve

Everything in the design is private **except the Activity Protocol route** that Microsoft 365 uses to deliver messages. Microsoft 365 and Teams don't support Private Link, so this is the [documented and only supported path](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network#step-5-review-the-network-path-and-security-controls). Present it to JNJ security architecture for an explicit decision. The control set is:

- The route exists only on agents where `enable_m365_public_endpoint` is set, and only for the `activityProtocol` path. Responses, Invocations, A2A, MCP, and management APIs stay private.
- Foundry manages source-IP filtering at its edge; client-supplied forwarding headers are ignored, and the filter fails closed.
- Signed Bot Framework token validation is bound to the agent identity, and the tenant check (`BotServiceTenant`) or tenant plus Azure RBAC check (`BotServiceRbac`) still applies.
- No customer public IP, inbound firewall rule, DNAT, or certificate exists.

A useful framing is: **"Inbound from Microsoft 365 is a service-to-service exception scoped to one route; all agent egress and data access remain private and firewall-governed."**

## Data handling to review with compliance

- When agents are published, Microsoft 365 and Teams process and store publishing metadata and conversation content under **Microsoft 365** terms, compliance commitments, and data residency. Agent state stays in JNJ-owned Cosmos DB, Storage, and AI Search. See the warning in the [publishing docs](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot).
- Assess each use case against JNJ's policies, such as GxP, privacy, and HIPAA where applicable, before broad audiences are approved. Start with non-regulated, documentation-style agents like this one.
- Keep the agent's tools on the firewall allow-list and in the toolbox. Each new tool or data source should go through the same review as the agent.

## Responsibilities (RACI-style)

| Activity | AI platform | Network | Security / IAM | M365 / Teams admin | Business owner |
|---|---|---|---|---|---|
| Foundry accounts, projects, models, capacity | **Owns** | Consulted | Consulted | | |
| Agent subnet, UDR, DNS, firewall allow-list | Consulted | **Owns** | Approves | | |
| Agent identities and RBAC; Azure Policy guardrails | Consulted | | **Owns** | | |
| Agent code, toolbox, and versions | **Owns** | | | | Consulted |
| Tenant-scope approval and audience groups | Requests | | Consulted | **Owns** | Approves |
| Teams availability, pinning, block or stop | | | | **Owns** | Consulted |
| Monitoring, incidents, kill switch | **Owns** | Consulted | Consulted | Executes block | Informed |

## Rollout path

1. **POC (this repository):** Prove the private build, MCP tool, publishing exception, and admin-approved scoped rollout.
2. **Landing zone pilot:** Re-deploy template 15 into a JNJ spoke with hub firewall and central DNS, use an in-VNet pipeline, and publish to a 25–50-person pilot group.
3. **Production pattern:** Add Azure Policy guardrails, dev/test/prod promotion, version pinning, evaluation gates before promotion, alerting on Application Insights and firewall denies, and a documented M365 approval runbook.
4. **Scale:** Use one Foundry project per business domain or data boundary. Share hub egress and DNS, and set per-agent audiences in the M365 admin center.

## Known limitations to set expectations

| Limitation | Impact |
|---|---|
| Published agents don't support streaming responses or citations in Teams or M365 Copilot. | The agent returns complete answers. In this POC, the agent places Learn URLs in the answer text instead of using citations. |
| File uploads and image generation don't work in M365 Copilot; they work in Teams. | Choose Teams for file-based scenarios. |
| Work IQ (Teams and Calendar MCP) isn't supported in network-isolated projects. | Use M365 data through supported connectors or tools, or keep Work IQ agents in a separate, non-isolated project. |
| Hosted-agent VNet injection must be set when the Foundry account is created. | You can't retrofit existing public accounts. Create new accounts in the landing zone. |
| The agent subnet can't be shared across Foundry accounts. | Plan one `/24` per Foundry account. |
