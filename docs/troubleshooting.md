# Troubleshooting: what we hit and how we fixed it

These are real issues from building this POC, with the evidence used to diagnose each one. All log queries run against `log-jnjm365-net` (Foundry edge and firewall) or `appi-tracing-lfzg` (agent traces).

## Status

| Surface | Result |
|---|---|
| Responses API from inside the VNet | ✅ Works; MCP tool calls succeed |
| **Microsoft Teams** | ✅ **Works end to end** after the fixes below, through both Option 1 (direct) and Option 2 (APIM) |
| Microsoft 365 Copilot | ⚠️ Messages reach the agent and answers are generated, but Copilot doesn't render the final answer. See [Open issue](#open-issue-m365-copilot-doesnt-render-the-final-answer). |

## 1. M365 or Teams calls blocked with a generic 403: missing `api-version` on the bot endpoint

**Symptom:** Copilot returns instantly with only the agent name, or shows *"still processing"* while the agent sees no traffic.

**Evidence:** Foundry `RequestResponse` logs show `Projects_Wildcard_Post` → **403** in about 5 ms from Teams source IPs (`52.112.x`, `52.123.x`) with a **99-byte** body. That body is the account-wide message `{"error":{"code":"403","message": "Public access is disabled. Please configure private endpoint."}}`.

**Diagnosis:** Over the public path, the `activityProtocol` route returns a *route-specific* `NetworkAccessDenied` error only when the URL includes `?api-version=v1`. Without it, the request doesn't match the source-IP-filtered Activity exception and falls through to the generic public-network-access block:

| Public request (with a valid token) | Result |
|---|---|
| `.../endpoint/protocols/activityProtocol?api-version=v1` | `403 NetworkAccessDenied`. The exception is evaluated; a non-Microsoft source IP is correctly rejected. |
| `.../endpoint/protocols/activityProtocol` | Generic 99-byte `403`. The exception is never evaluated. |

**Fix:** Set the Azure Bot Service messaging endpoint to:

```text
https://<account>.services.ai.azure.com/api/projects/<project>/agents/<agent>/endpoint/protocols/activityProtocol?api-version=v1
```

[publish-agent.ps1](../scripts/publish-agent.ps1) now does this. After the change, the same Teams IPs received **202 Accepted**. Allow about 10 minutes for the channel to pick up the new endpoint.

> The Bicep sample in the Learn article omits `?api-version=v1` on the bot endpoint. Without it, private-network publishing fails as described above.

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES" and TimeGenerated > ago(1h)
| where CallerIPAddress startswith "52.11" or CallerIPAddress startswith "52.12"
| project TimeGenerated, OperationName, ResultSignature, DurationMs, CallerIPAddress,
          responseLength = extract('"responseLength":([0-9]+)', 1, properties_s)
```

`deploy-infra.ps1` turns on these logs by adding the `to-poc-log-analytics` diagnostic setting for Audit, RequestResponse, and Trace. A subscription policy may already send them elsewhere.

## 2. Teams: "This app isn't part of your Teams" / Request access

**Cause:** Approval in the M365 admin center scoped the agent store, but Teams app-centric availability for the new custom app was still restricted.

**Fix:** In the Teams admin center, go to **Teams apps** > **Manage apps** > **JNJ Azure Advisor** > **Users and groups**, and add `sg-jnj-azure-advisor-pilot`. See [governance.md](governance.md#enable-it-in-teams-teams-admin-center).

## 3. Slow first reply (cold start) on a new conversation

**Evidence:** In App Insights, `Inbound POST /responses completed with status 200 in 29842ms`. The container started about 20 seconds before the agent's first MCP call.

**Fix:** Increase the hosted-agent container size in `agent/azure.yaml` from 0.5 CPU / 1 GiB to **1 CPU / 2 GiB**, then redeploy. A cold request dropped to about 13.6 seconds, and warm requests take 3–4 seconds. The published endpoint follows `@latest`, so you don't need to republish.

## 4. Conversation stuck after a failure

**Fix:** In Teams, send `/foundry_new_preview` to the agent. In M365 Copilot, start a new chat ([Learn](https://learn.microsoft.com/azure/foundry/agents/how-to/troubleshoot-publish-copilot#reset-a-conversation)).

## 5. Jumpbox scripts fail with "Cannot modify extensions in the VM when the VM is not running"

**Cause:** The jumpbox was deallocated, likely by a subscription auto-shutdown policy. Run Command needs a running VM.

**Fix:** Run `az vm start -g rg-jnj-foundry-m365-poc -n vm-jnjm365-jumpbox`. Only private data-plane work, such as deploying, invoking, or publishing, needs the VM. Teams and Copilot traffic doesn't.

## 6. Capacity errors in East US 2

- **AI Search Standard:** The deployment returned `InsufficientResourcesAvailable`. Bring a Search service from Central US with `deploy-infra.ps1 -AiSearchResourceId`; its private endpoint still lives in the East US 2 VNet.
- **VM sizes:** The deployment returned `SkuNotAvailable` for `Standard_D2s_v5`. The jumpbox now uses `Standard_D2s_v7` with NVMe.
- **VPN Gateway:** Zone-redundant gateways repeatedly returned `VmssGatewayDeploymentFailed`. The gateway now lives in a peered **hub VNet in Central US**, matching the JNJ hub-spoke pattern.

## 7. Tenant-scope agent through APIM never receives chat messages

**Symptom:** The first Option 2 agent, *JNJ Azure Advisor (via APIM)*, was approved and **pre-installed** for the pilot group. In Teams it never replied.

**Evidence:**

- `ApiManagementGatewayLogs` showed only the two install-time POSTs, which passed `validate-jwt` with backend 202. No chat message ever reached APIM, including messages sent from a new 1:1 chat opened with `https://teams.microsoft.com/l/chat/0/0?users=28:<client-id>`.
- The Bot Service resource, the Teams manifest `botId`, and the agent identity all matched. Kai was in the pilot group.
- Changing the APIM backend `api-version` and toggling `enable_m365_public_endpoint` made no difference, because nothing was being delivered.
- In parallel, a **Shared-scope** copy (`jnj-azure-advisor-apim2`) using the same APIM, the same policy, and `api-version=v1` answered through APIM. That ruled out the network path.

**Fix:** A clean reset. Delete the agent in the M365 admin center, then publish a **new** agent (`jnj-advisor-apim-tenant`) with Tenant scope through APIM. Approve it for the group as **Available to**, not **Installed for**, and enable it in the Teams admin center. It answered on the first message: Teams → APIM 202 → Foundry `10.50.4.x` 202 → `create_response` 200.

**Lessons:**

- Point the bot at APIM **before** the first Tenant publish and approval.
- Don't pre-install during testing; users can't remove a pre-installed app to reset it.
- If a Tenant-scope agent never receives messages, republish it under a new agent name rather than over a deleted M365 title.

**Noise to expect:** The public APIM gateway is probed by internet scanners. These requests show up as `404` with an empty `OperationId` in `ApiManagementGatewayLogs` and never reach Foundry. Filter on `OperationId != ""` to see real Microsoft 365 traffic.

## Open issue: M365 Copilot doesn't render the final answer

| Hop | Evidence | Status |
|---|---|---|
| Copilot → Foundry Activity route | `Projects_Wildcard_Post` **202** from `52.112.x` | ✅ |
| Foundry sign-in card | User completed sign-in | ✅ |
| Foundry → hosted agent → Learn MCP → model | App Insights shows `Inbound POST /responses ... 200`. The answer text appears in traces, and `create_response` returned 200 with a 24–27 KB body. | ✅ |
| Interim update to Copilot ("Please wait while I process your request") | Rendered in Copilot | ✅ |
| Final answer in **Copilot** | Not rendered. **Teams renders it.** | ❌ |

Because the same agent, Bot Service, and Activity route work in Teams, the remaining gap is in the M365 Copilot channel's delivery or rendering for this agent, not in the private network. Next steps:

### Isolation test (2026-10-19)

| Agent | Teams | M365 Copilot |
|---|---|---|
| `jnj-azure-advisor`: hosted agent, Agent Framework, Learn MCP toolbox | ✅ Answers | ❌ Shows the agent name or icon with an empty body |
| `jnj-prompt-test`: prompt agent with no container or tools, published with `Shared` scope | n/a | ❌ Same empty reply |

In both cases, Foundry accepts Copilot's calls (`Projects_Wildcard_Post` **202** from `52.112.x`). The hosted agent's traces show the full answer generated in 12–22 seconds, and a warm follow-up in the same chat also doesn't render. **The issue doesn't depend on agent type, agent code, tools, or latency.** It's in how M365 Copilot handles replies from Foundry agents published through the private-network Activity route, while Teams handles them correctly.

`jnj-prompt-test` (bot `bot-jnj-prompt-test-jnjm365fdylfzg`, Teams app ID `256c38af-4bc5-4b95-bdad-d13532f63fbb`) is kept as the **minimal reproduction** for the support case. Remove it when the case is closed:

```powershell
az resource delete --ids /subscriptions/<sub>/resourceGroups/rg-jnj-foundry-m365-poc/providers/Microsoft.BotService/botServices/bot-jnj-prompt-test-jnjm365fdylfzg
# then DELETE {project_endpoint}/agents/jnj-prompt-test?api-version=v1 from inside the VNet
```

Next steps:

1. Open a support case with Foundry Agent Service publishing, using `jnj-prompt-test` as the minimal reproduction. Include:
   - The `RequestResponse` correlation IDs, such as `ce0c2537-1e17-49ad-8c96-351fc1f93a2d` and `5ca492fa-3ad7-4348-b39b-b1c2356299b6`
   - The App Insights `x-request-id` for the hosted agent, such as `f964765df05f4c670930fe4586a2d164`
   - The Copilot `ConversationId`
   - Context: the project has public network access disabled, `enable_m365_public_endpoint` is set to `true`, Teams works, and Copilot shows an empty reply
2. Until the case is resolved, use **Teams**, or **Copilot in Teams**, for the JNJ demo.
