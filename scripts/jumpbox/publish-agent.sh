# Enables the source-IP-filtered public Activity Protocol route and publishes the agent to
# Microsoft 365 Copilot and Teams. Runs on the jumpbox (inside the VNet) because the agent
# management APIs remain private.
# Env: AZURE_AI_PROJECT_ENDPOINT, AGENT_NAME, BOT_SERVICE_ID, PUBLISH_SCOPE, APP_VERSION,
#      AGENT_DISPLAY_NAME, SHORT_DESCRIPTION, FULL_DESCRIPTION, DEVELOPER_NAME,
#      DEVELOPER_URL, PRIVACY_URL, TERMS_URL, USER_TOKEN (protected)
# Ref: https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network
LOG=/var/log/poc/publish-agent.log
exec > >(tee -a "$LOG") 2>&1

AUTH=(-H "Authorization: Bearer ${USER_TOKEN}")
AGENT_URL="${AZURE_AI_PROJECT_ENDPOINT}/agents/${AGENT_NAME}"

# Tenant scope pairs with BotServiceTenant; Shared/Personal pair with BotServiceRbac.
if [ "$PUBLISH_SCOPE" = "Tenant" ]; then BOT_SCHEME=BotServiceTenant; else BOT_SCHEME=BotServiceRbac; fi

echo "--- Step 3: enable Activity Protocol public route + ${BOT_SCHEME}"
current=$(curl -sS --fail-with-body "${AGENT_URL}?api-version=v1" "${AUTH[@]}")
# PATCH replaces protocol_configuration and authorization_schemes, so merge with what exists.
patch=$(echo "$current" | jq --arg scheme "$BOT_SCHEME" '{
  agent_endpoint: {
    protocol_configuration: ((.agent_endpoint.protocol_configuration // {responses: {}})
      + {activity: {enable_m365_public_endpoint: true}}),
    authorization_schemes: ((((.agent_endpoint.authorization_schemes // [{type: "Entra"}])
      | map(select(.type != "BotServiceRbac" and .type != "BotServiceTenant")))
      + [{type: $scheme}]) | unique_by(.type))
  }
}')
echo "$patch" | jq .
curl -sS --fail-with-body -X PATCH "${AGENT_URL}?api-version=v1" "${AUTH[@]}" \
  -H "Content-Type: application/merge-patch+json" -d "$patch" | jq '{name, agent_endpoint}'

body=$(jq -n \
  --arg name "$AGENT_DISPLAY_NAME" --arg bot "$BOT_SERVICE_ID" --arg scope "$PUBLISH_SCOPE" \
  --arg ver "$APP_VERSION" --arg short "$SHORT_DESCRIPTION" --arg full "$FULL_DESCRIPTION" \
  --arg dev "$DEVELOPER_NAME" --arg devUrl "$DEVELOPER_URL" --arg privacy "$PRIVACY_URL" --arg terms "$TERMS_URL" \
  '{agentDisplayName: $name, botServiceArmId: $bot, publishScope: $scope, publishAsAutopilot: false,
    appVersion: $ver, shortDescription: $short, fullDescription: $full, developerName: $dev,
    developerWebsiteUrl: $devUrl, privacyUrl: $privacy, termsOfUseUrl: $terms}')

echo "--- Optional: download and validate the generated Teams app package"
curl -sS --fail-with-body -X POST "${AGENT_URL}/microsoft365/zip?api-version=v1" "${AUTH[@]}" \
  -H "Content-Type: application/json" -d "$body" -o /opt/poc/appPackage.zip
python3 -c "import zipfile,json; z=zipfile.ZipFile('/opt/poc/appPackage.zip'); m=json.loads(z.read('manifest.json')); print(json.dumps({'files': z.namelist(), 'name': m.get('name'), 'version': m.get('version'), 'id': m.get('id'), 'bots': [b.get('botId') for b in m.get('bots', [])], 'copilotAgents': m.get('copilotAgents')}, indent=2))"

echo "--- Step 4: publish (scope=${PUBLISH_SCOPE}, appVersion=${APP_VERSION})"
curl -sS --fail-with-body -X POST "${AGENT_URL}/microsoft365/publish?api-version=v1" "${AUTH[@]}" \
  -H "Content-Type: application/json" -d "$body" | jq .
