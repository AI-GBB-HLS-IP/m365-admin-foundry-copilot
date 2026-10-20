# Creates (or adds a new version of) a prompt agent with the Microsoft Learn MCP tool.
# Runs on the jumpbox (inside the VNet). Env: AZURE_AI_PROJECT_ENDPOINT, AGENT_NAME, MODEL,
# INSTRUCTIONS, DESCRIPTION, USER_TOKEN (protected)
AUTH=(-H "Authorization: Bearer ${USER_TOKEN}" -H 'Content-Type: application/json')
EP="$AZURE_AI_PROJECT_ENDPOINT"

definition=$(jq -n --arg model "$MODEL" --arg instr "$INSTRUCTIONS" '{kind: "prompt", model: $model, instructions: $instr,
  tools: [{type: "mcp", server_label: "microsoft_learn", server_url: "https://learn.microsoft.com/api/mcp", require_approval: "never"}]}')

code=$(curl -sS -o /dev/null -w '%{http_code}' "${EP}/agents/${AGENT_NAME}?api-version=v1" "${AUTH[@]}")
if [ "$code" = "404" ]; then
  body=$(jq -n --arg name "$AGENT_NAME" --arg desc "$DESCRIPTION" --argjson def "$definition" '{name: $name, description: $desc, definition: $def}')
  url="${EP}/agents?api-version=v1"
else
  body=$(jq -n --arg desc "$DESCRIPTION" --argjson def "$definition" '{description: $desc, definition: $def}')
  url="${EP}/agents/${AGENT_NAME}/versions?api-version=v1"
fi
curl -sS --fail-with-body -X POST "$url" "${AUTH[@]}" -d "$body" \
  | jq '{name, version: (.versions.latest.version // .version), identity: (.instance_identity.client_id // null)}'

echo "--- smoke test (private endpoint)"
curl -sS -m 180 "${EP}/agents/${AGENT_NAME}/endpoint/protocols/openai/responses?api-version=v1" -X POST "${AUTH[@]}" \
  -d '{"input":"In one sentence, what is a Foundry hosted agent? Cite a Microsoft Learn URL."}' -o /tmp/prompt-agent.json
jq -r '.status, ([.output[]? | .type] | join(",")), ([.output[]? | select(.type=="message") | .content[]?.text] | join(" ")), (.error // empty | tostring)' /tmp/prompt-agent.json | head -c 1200
