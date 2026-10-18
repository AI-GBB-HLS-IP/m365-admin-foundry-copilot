# Installs the tooling needed to operate the private Foundry project from inside the VNet.
# Runs as root through Azure Run Command. Idempotent.
LOG=/var/log/poc/bootstrap.log
exec > >(tee -a "$LOG") 2>&1

if [ -f /var/lib/poc/bootstrap.done ] && command -v azd >/dev/null && command -v az >/dev/null; then
  echo "Tooling already installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null) / $(azd version 2>/dev/null | head -1)"
else
  apt-get update -qq
  apt-get install -y -qq curl jq unzip ca-certificates dnsutils python3 python3-venv >/dev/null
  if ! command -v az >/dev/null; then
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash >/dev/null
  fi
  if ! command -v azd >/dev/null; then
    curl -fsSL https://aka.ms/install-azd.sh | bash >/dev/null
  fi
  mkdir -p /var/lib/poc && touch /var/lib/poc/bootstrap.done
fi

# Foundry azd extensions (agents, toolboxes, connections, projects, ...).
if ! azd extension list --installed 2>/dev/null | grep -q '^microsoft.foundry'; then
  azd extension install microsoft.foundry --no-prompt >/dev/null || azd extension install microsoft.foundry
fi
azd extension upgrade --all --no-prompt >/dev/null 2>&1 || true

# Sign in with the VM's system-assigned managed identity (no secrets on the box).
az login --identity --allow-no-subscriptions --output none
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
azd auth login --managed-identity >/dev/null

echo "az:  $(az version --query '"azure-cli"' -o tsv)"
echo "azd: $(azd version | head -1)"
azd extension list --installed | grep -E 'azure.ai|microsoft.foundry' || true
