# How to govern the agent

Governance for a Foundry agent that is published to Teams and Microsoft 365 Copilot happens in **four layers**. Each layer has a clear owner, and any layer can stop the agent.

| Layer | Question it answers | Where it is controlled | Typical owner |
|---|---|---|---|
| 1. Build | Who can create, change, and publish agents? Which tools and data can an agent reach? | Azure RBAC, Foundry project, Foundry Toolbox, Azure Firewall, Azure Policy | AI platform and cloud security teams |
| 2. Publish | Can this agent be offered to the organization? | Foundry `publishScope` and Microsoft 365 admin center **Requests** | AI governance board / M365 admin |
| 3. Access | Who, and how many people, can discover, install, and use it? | M365 admin center **Agent Registry**, Teams admin center, Entra security groups | M365 / Teams admin |
| 4. Operate | Is it behaving well? How do we roll back or stop it? | Agent versions, Application Insights, firewall logs, Activity Log, kill switches | AI platform / SecOps |

## Layer 1: Build-time controls (Azure / Foundry)

| Control | How it works in this POC |
|---|---|
| **Who can build or publish** | Only principals with **Foundry User** (formerly Azure AI User) on the project can create agent versions or call the publish API. Azure **Owner** alone grants no Foundry data actions. Publishers also need Bot Service write permissions in the resource group. |
| **Where builders can work** | `publicNetworkAccess: Disabled`. Agents can only be created or changed from inside the network (jumpbox, ExpressRoute, VPN, or an in-VNet CI/CD runner), even by Owners. |
| **What tools an agent can use** | The agent can call only the tools in its **Foundry Toolbox** (`learn-tools`), which is a versioned MCP endpoint. Changing tools creates a new toolbox version that must be promoted. |
| **Where tools can connect** | Azure Firewall allows only FQDNs on the allow-list, such as `learn.microsoft.com`. A new MCP server or API requires a firewall change. Logs show every allowed or denied call. |
| **Where data lives** | Standard Agent Setup keeps threads, files, and vectors in customer-owned Cosmos DB, Storage, and AI Search behind private endpoints. |
| **Agent identity** | Each published agent has its own Microsoft Entra agent identity (`instance_identity`). Grant it only the roles it needs. Here, Foundry User on the project lets it call the model and toolbox. |
| **Guardrails at scale** | Use Azure Policy to deny Cognitive Services accounts with public network access, require private endpoints, and restrict allowed regions or SKUs. Template 15 sets `disableLocalAuth`, so callers must use keyless Entra ID authentication. |

## Layer 2: Publish-time controls (approval)

The `publishScope` in the publish API determines both **visibility** and **authorization**. Publishing replaces any different Bot Service authorization scheme on the endpoint.

| `publishScope` | Visibility | Who can *call* the agent | Admin approval |
|---|---|---|---|
| `Shared` (portal: "Just you") | Only the publisher, under **Your agents**; the publisher can share a link | `BotServiceRbac`: only users who also hold Foundry permissions on the project | Not required |
| `Tenant` (portal: "People in your organization") | After approval, the selected audience sees it under **Built by your org** | `BotServiceTenant`: users in the tenant | **Required** in the M365 admin center |

This POC publishes with **`Tenant`**, so the agent remains unavailable until an M365 admin approves it.

### Approve and scope the audience (M365 admin center)

1. Go to the [M365 admin center](https://admin.cloud.microsoft/?#/agents/all/requested), then select **Agents** > **All agents** > **Requests**.
2. Select **JNJ Azure Advisor**. Review its description, owner, capabilities, data sources, and actions.
3. Select **Publish to store**.
4. **Select the users or groups that can install the agent.** This control limits who, and therefore how many people, can use the agent. For the pilot, choose the Entra security group `sg-jnj-azure-advisor-pilot` instead of **Everyone**.
5. Optionally, select users or groups for whom the agent is **preinstalled**.
6. Choose a policy template (default or custom), review permissions, and grant admin consent if appropriate.
7. Select **Publish**.

### Enable it in Teams (Teams admin center)

Approving the agent in the M365 admin center doesn't necessarily make it available in **Teams**. Teams applies its own per-app availability through app-centric management, and many tenants set new custom apps to **No one** by default. If users see *"This app isn't part of your Teams"* and **Request access**, make these changes in the Teams admin center:

1. Go to the [Teams admin center](https://admin.teams.microsoft.com/), then select **Teams apps** > **Manage apps** > **JNJ Azure Advisor**. Confirm that **Status** is *Allowed* and the app is *Published*.
2. Select **Users and groups** > **Edit availability** > **Specific users or groups**, then add `sg-jnj-azure-advisor-pilot`.
3. Under **Org-wide app settings**, confirm that custom apps are allowed.
4. Approve any pending user requests for the app.

Use the same security group in both admin centers so the M365 Copilot and Teams audiences match. A **security group** under **Teams & groups** > **Security groups** is the right type. You don't need a Microsoft 365 group or a Team.

To reject the agent, select **Reject submission**. Later metadata updates, such as a new `appVersion`, appear as **Pending update**. Users continue to see the previously approved version until an admin selects **Update in store**.

> Changing the agent's *code* or *model* creates a new Foundry agent version and doesn't require M365 re-approval. Control version promotion in Foundry (Layer 4); see [Update a published agent](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot#update-a-published-agent-in-m365teams).

## Layer 3: Access controls (who, and how many people)

| Need | Control |
|---|---|
| Limit the agent to a pilot cohort, such as 25 people | When publishing to the store, assign the agent to an Entra security group. The group's membership is the user count. Add or remove people through the group, or through an Entra access package with approvals and expiry. |
| Expand or shrink the audience later | **Agent Registry**: **Agents** > **All agents** > **Registry**. Select the agent, then edit its users and groups, **Install** it for users or groups, or **Uninstall** it. |
| Make it easy to find | In the Registry, **Install** preinstalls the agent; **Manage pinned agents** pins it in Copilot. |
| Teams-specific availability | In [Teams admin center](https://admin.teams.microsoft.com/), go to **Teams apps** > **Manage apps**, select the agent, then select **Users and groups** > **Edit availability**. Choose **Everyone**, **Specific users or groups**, or **No one** (app-centric management). |
| Default for every new org-built agent | In the Teams admin center, set new custom apps to **No one** or an admin group by default so nothing reaches users before review. |
| Hard technical gate for very small pilots | Publish with `Shared` (`BotServiceRbac`). Only users with Foundry User on the project can call the agent, regardless of what the store shows. |
| Inventory and audit | **Agent Registry** > **Export** creates a CSV of every agent, publisher type, channel, and owner. The **Agents without owners** count helps identify orphaned agents. |

## Layer 4: Operate, monitor, and stop

### Versioning and rollback

- Every `azd deploy` creates an immutable agent version. By default, the published endpoint serves the latest version.
- To control production rollout, pin traffic with the agent `version_selector`. Use `FixedRatio` to send 100% of traffic to a version, or split traffic for canary releases. To roll back, point the selector back to the previous version; you don't need to republish.

### Monitoring

| Signal | Where |
|---|---|
| Agent traces: requests, tool calls, latency, errors | Application Insights, through the AMPLS private endpoint. Also visible on the Foundry agent's **Monitor** tab. |
| Tool egress (allowed or denied destinations) | Azure Firewall logs in `log-jnjm365-net`. See the KQL in [networking.md](networking.md). |
| Who changed or published what | Azure Activity Log for ARM changes, such as the Bot Service. Use Foundry diagnostic logs for data-plane operations. |
| M365 adoption and inventory | M365 admin center **Agents** pages and Registry export |

### Kill switches (fastest first)

| Action | Effect | Where |
|---|---|---|
| **Block** the agent | Prevents all users in the tenant from using it | M365 admin center > Agent Registry |
| **Stop** the agent | Stops the underlying Azure infrastructure for the Foundry agent | M365 admin center > Agent Registry (Foundry agents) |
| Set Teams availability to **No one** | Removes the agent from Teams | Teams admin center |
| Disable the public Activity route | PATCH `enable_m365_public_endpoint: false` or remove the Bot Service authorization scheme. Teams and Copilot traffic is then rejected at the Foundry edge. | Foundry REST from inside the VNet |
| Remove the tool's FQDN | The agent can no longer reach the MCP server. | Azure Firewall policy |
| Delete the agent from the store | Removes it, with a 30-day recovery window | M365 admin center |

## Demo script (governance)

1. **Before approval:** Show that Kai can't find *JNJ Azure Advisor* under **Built by your org**. In the M365 admin center, show it in **Requests** as **Pending review**.
2. **Approve with scope:** Publish it to the store for `sg-jnj-azure-advisor-pilot` only. Show the group membership, which represents the number of users.
3. **Use:** In Teams, open **Apps** > **Built by your org** > **JNJ Azure Advisor** and ask *"How do I publish a Foundry agent to Teams from a private network?"* The answer cites Microsoft Learn through the MCP tool.
4. **Observe:** Show the `learn.microsoft.com` allow entries in firewall logs and the trace in Application Insights.
5. **Restrict:** Remove a user from the group, or set Teams availability to a narrower group.
6. **Kill switch:** In the Agent Registry, **Block** the agent, show that it's unavailable, and then **Unblock** it.

## References

- [Publish agents to Microsoft Copilot and Teams](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot)
- [Agent requests in the Microsoft 365 admin center](https://learn.microsoft.com/microsoft-365/admin/manage/agent-requests)
- [Governance and lifecycle actions for agents](https://learn.microsoft.com/microsoft-365/admin/manage/agent-actions)
- [Agent Registry](https://learn.microsoft.com/microsoft-365/admin/manage/agent-registry)
- [App-centric management in Teams](https://learn.microsoft.com/microsoftteams/app-centric-management)
- [Role-based access control for Foundry](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)
