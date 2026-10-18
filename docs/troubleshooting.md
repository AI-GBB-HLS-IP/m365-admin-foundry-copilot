# Troubleshooting: what we hit and how we fixed it

These are real issues from building this POC, with the evidence used to diagnose each one. All log queries run against `log-jnjm365-net` (Foundry edge and firewall) or `appi-tracing-lfzg` (agent traces).

## Status

| Surface | Result |
|---|---|
| Responses API from inside the VNet | ✅ Works; MCP tool calls succeed |
| **Microsoft Teams** | ✅ **Works end to end** after the fixes below |
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

## Open issue: M365 Copilot doesn't render the final answer

| Hop | Evidence | Status |
|---|---|---|
| Copilot → Foundry Activity route | `Projects_Wildcard_Post` **202** from `52.112.x` | ✅ |
| Foundry sign-in card | User completed sign-in | ✅ |
| Foundry → hosted agent → Learn MCP → model | App Insights shows `Inbound POST /responses ... 200`. The answer text appears in traces, and `create_response` returned 200 with a 24–27 KB body. | ✅ |
| Interim update to Copilot ("Please wait while I process your request") | Rendered in Copilot | ✅ |
| Final answer in **Copilot** | Not rendered. **Teams renders it.** | ❌ |

Because the same agent, Bot Service, and Activity route work in Teams, the remaining gap is in the M365 Copilot channel's delivery or rendering for this agent, not in the private network. Next steps:

1. Retry in a brand-new Copilot chat now that the endpoint fix has propagated. Compare the *Copilot in Teams* experience with *M365 Copilot app/web*.
2. If the issue persists, open a support case with Foundry Agent Service publishing. Include the `RequestResponse` correlation IDs, the App Insights `x-request-id` for the matching `/responses` call, and the Copilot `ConversationId`. The Learn troubleshooting page lists these values for support.
