# Deploys the Microsoft Learn MCP toolbox and the hosted agent with azd, then smoke-tests it.
# Runs as root on the jumpbox (inside the VNet) through Azure Run Command.
LOG=/var/log/poc/deploy-agent.log
exec > >(tee -a "$LOG") 2>&1

cd /opt/poc/agent
export AZURE_DEV_COLLECT_TELEMETRY=no

if ! azd env list 2>/dev/null | grep -q "^${AZD_ENV_NAME} "; then
  azd env new "$AZD_ENV_NAME" --subscription "$AZURE_SUBSCRIPTION_ID" --location "$AZURE_LOCATION" --no-prompt
fi
azd env select "$AZD_ENV_NAME"

azd env set AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID"
azd env set AZURE_TENANT_ID "$AZURE_TENANT_ID"
azd env set AZURE_LOCATION "$AZURE_LOCATION"
azd env set AZURE_RESOURCE_GROUP "$AZURE_RESOURCE_GROUP"
azd env set AZURE_AI_ACCOUNT_NAME "$AZURE_AI_ACCOUNT_NAME"
azd env set AZURE_AI_PROJECT_NAME "$AZURE_AI_PROJECT_NAME"
azd env set AZURE_AI_PROJECT_ID "$AZURE_AI_PROJECT_ID"
azd env set AZURE_AI_PROJECT_ENDPOINT "$AZURE_AI_PROJECT_ENDPOINT"
azd env set FOUNDRY_PROJECT_ENDPOINT "$AZURE_AI_PROJECT_ENDPOINT"
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "$AZURE_AI_MODEL_DEPLOYMENT_NAME"

echo "--- Private DNS check (should be 10.50.1.x)"
getent hosts "${AZURE_AI_ACCOUNT_NAME}.services.ai.azure.com" || true

echo "--- azd deploy (toolbox + hosted agent)"
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd deploy --no-prompt

echo "--- Toolbox"
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai toolbox show learn-tools --output json \
  | jq '{name, default_version, endpoint: (.mcp_endpoint // .endpoint // .properties.mcp_endpoint)}' || true

echo "--- Agent"
AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai agent show --output json \
  | jq '{name, version: (.version // .latest_version), status}' || true

echo "--- Smoke test (Responses protocol, private endpoint; first call includes cold start)"
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
URL="${AZURE_AI_PROJECT_ENDPOINT}/agents/jnj-azure-advisor/endpoint/protocols/openai/responses?api-version=v1"
for attempt in 1 2 3; do
  code=$(curl -sS -m 300 -o /tmp/smoke.json -w '%{http_code}' -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d '{"input":"In two bullets, what is a Foundry hosted agent? Use Microsoft Learn and cite sources."}' || echo 000)
  status=$(jq -r '.status // empty' /tmp/smoke.json 2>/dev/null || true)
  echo "attempt ${attempt}: HTTP ${code} status=${status}"
  if [ "$status" = "completed" ]; then
    jq -r '[.output[]? | select(.type=="message") | .content[]?.text] | join("\n")' /tmp/smoke.json | head -c 2000
    exit 0
  fi
  head -c 800 /tmp/smoke.json 2>/dev/null; echo
  sleep 20
done
exit 1
