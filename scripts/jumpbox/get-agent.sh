# Reads the hosted agent from the private project endpoint and prints the values needed to
# create the Azure Bot Service resource. Runs on the jumpbox (inside the VNet).
# Env: AZURE_AI_PROJECT_ENDPOINT, AGENT_NAME, USER_TOKEN (protected, audience https://ai.azure.com)
AGENT_URL="${AZURE_AI_PROJECT_ENDPOINT}/agents/${AGENT_NAME}?api-version=v1"

agent=$(curl -sS --fail-with-body "$AGENT_URL" -H "Authorization: Bearer ${USER_TOKEN}")
echo "$agent" | jq '{name, instance_identity, agent_endpoint}'
echo "AGENT_CLIENT_ID=$(echo "$agent" | jq -r '.instance_identity.client_id')"
echo "AGENT_PRINCIPAL_ID=$(echo "$agent" | jq -r '.instance_identity.principal_id')"
