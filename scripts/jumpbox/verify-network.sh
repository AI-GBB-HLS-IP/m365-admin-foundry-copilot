# Verifies private DNS resolution and egress control from inside the VNet.
# Env: AZURE_AI_ACCOUNT_NAME, AZURE_AI_PROJECT_ENDPOINT, PRIVATE_HOSTS (space separated)
echo "--- Private endpoint DNS (expect 10.50.1.x)"
for h in $PRIVATE_HOSTS; do
  printf '%-60s %s\n' "$h" "$(getent hosts "$h" | awk '{print $1}' | head -1)"
done

echo "--- Foundry data plane from inside the VNet (expect 401 = reachable, auth required)"
curl -s -o /dev/null -w '%{http_code}\n' "${AZURE_AI_PROJECT_ENDPOINT}/agents?api-version=v1"

echo "--- Jumpbox egress through Azure Firewall (expect 405: MCP endpoint reachable, requires POST)"
curl -s -o /dev/null -w 'learn.microsoft.com %{http_code}\n' https://learn.microsoft.com/api/mcp || true
echo "--- Public egress IP seen by the internet (should be the firewall public IP)"
curl -s https://api.ipify.org; echo
