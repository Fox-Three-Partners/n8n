#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------------
# deploy-to-azure-containerapps.sh
# --------------------------------------------------------------------------------------------------
# Automated deployment script for n8n to Microsoft Azure using Azure Container Apps and
# Azure Database for PostgreSQL – Flexible Server.
#
# This script provisions all required Azure resources:
#   1. Resource Group
#   2. Log Analytics Workspace
#   3. Azure Container Apps Environment
#   4. Azure Database for PostgreSQL Flexible Server (with basic firewall rule)
#   5. Container App running a locally-built n8n image (default: "n8n-local:dev")
#
# It applies best-practice configurations for security, cost-efficiency, and scalability:
#   • Serverless Consumption plan with scale-to-zero
#   • Secrets stored in Container Apps Secrets instead of plain env vars
#   • Minimal-cost burstable Postgres SKU (B1ms) with automatic backups
#   • Basic authentication and encryption key pre-configured for n8n
#
# The script features:
#   • Robust error handling with automatic rollback (delete partially-created resources)
#   • Detailed logging with timestamps
#   • Idempotent re-runs (existing resources will be reused)
#
# Prerequisites:
#   • Azure CLI ≥ 2.44 (https://learn.microsoft.com/cli/azure/install-azure-cli)
#   • `az extension add --name containerapp` (script installs/updates automatically)
#   • Logged-in Azure session: `az login`
#   • Bash 4+ (associative arrays)
#
# Usage:
#   ./deploy-to-azure-containerapps.sh -g <resource-group> -l <location> \
#       -p <postgres-admin-password> -u <basic-auth-user> -s <basic-auth-pass>
#
# All options have sane defaults and can also be set via environment variables.
# Run with -h to see full options.
# --------------------------------------------------------------------------------------------------

set -Eeuo pipefail

# ===== Global config ===== #
SCRIPT_NAME=$(basename "$0")
DEFAULT_LOCATION="eastus"
DEFAULT_RG="n8n-rg"
DEFAULT_ENV="n8n-env"
DEFAULT_APP="n8n-app"
DEFAULT_PG_SERVER="n8ndb"
DEFAULT_PG_DB="n8n"
DEFAULT_PG_SKU="Standard_B1ms"   # cheapest burstable with 1 vCPU, 2 GiB
DEFAULT_PG_VERSION="15"
DEFAULT_CPU="1.0"
DEFAULT_MEMORY="2.0Gi"
DEFAULT_MIN_REPLICAS="0"
DEFAULT_MAX_REPLICAS="5"
DEFAULT_IMAGE="n8n-local:dev"

# ===== Local image build helper ===== #
# If the requested image tag is not available locally, attempt to build it from the current
# working copy using the existing build scripts (build-n8n.mjs & dockerize-n8n.mjs).
#
# The helper honours a BUILD_LOCAL_IMAGE env flag. If set to "false" the build will be skipped
# even if the image does not exist (useful when the user wants to rely on an already-pushed
# image or a different workstation).

BUILD_LOCAL_IMAGE=${BUILD_LOCAL_IMAGE:-true}

ensure_local_image() {
  local img="$1"
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "Docker image '$img' already present locally – skipping build."
    return
  fi

  if [[ "$BUILD_LOCAL_IMAGE" != "true" ]]; then
    die "Image '$img' not found locally and BUILD_LOCAL_IMAGE=false – aborting."
  fi

  log "Docker image '$img' not found locally – building from source…"

  # Derive base name and tag (default to 'latest' when no tag supplied)
  local base_name="${img%%:*}"
  local tag="${img##*:}"
  if [[ "$base_name" == "$tag" ]]; then
    tag="latest"
  fi

  # Build production artefacts
  node "$(dirname "$0")/build-n8n.mjs"

  # Build docker image with matching name & tag
  IMAGE_BASE_NAME="$base_name" IMAGE_TAG="$tag" node "$(dirname "$0")/dockerize-n8n.mjs"

  if ! docker image inspect "$img" >/dev/null 2>&1; then
    die "Local build of image '$img' failed – cannot continue."
  fi

  # If the image is targeting an Azure Container Registry (e.g. myreg.azurecr.io/...), push it
  if [[ "$base_name" == *.azurecr.io/* ]]; then
    local acr_name="${base_name%%.*}"
    log "Pushing image to Azure Container Registry '$acr_name'…"
    az acr login --name "$acr_name" >/dev/null 2>&1 || die "Failed to login to ACR '$acr_name'"
    docker push "$img" || die "Failed to push image '$img' to ACR."
    log "Image '$img' pushed to ACR successfully."
  fi

  log "Successfully built local Docker image '$img'."
}

# ===== Helper functions ===== #
log() {
  # Prints message with timestamp
  local level="${2:-INFO}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $1"
}

die() {
  log "$1" "ERROR"
  exit 1
}

cleanup() {
  # Delete resource group if it was newly created and script failed before completion
  if [[ "${ROLLBACK_ON_ERROR}" == "true" && "${RG_CREATED}" == "true" ]]; then
    log "Rolling back: deleting resource group $RESOURCE_GROUP" "WARN"
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait || true
  fi
}
trap cleanup ERR

show_help() {
  cat <<EOF
$SCRIPT_NAME – Deploy n8n on Azure Container Apps

Options:
  -g  Azure Resource Group name          (default: $DEFAULT_RG)
  -l  Azure Region/location              (default: $DEFAULT_LOCATION)
  -e  Container Apps Environment name    (default: $DEFAULT_ENV)
  -a  Container App name                 (default: $DEFAULT_APP)
  -i  Docker image for n8n               (default: $DEFAULT_IMAGE)
  -c  CPU cores for container            (default: $DEFAULT_CPU)
  -m  Memory for container (Gi)          (default: $DEFAULT_MEMORY)
  -r  Min replicas                       (default: $DEFAULT_MIN_REPLICAS)
  -x  Max replicas                       (default: $DEFAULT_MAX_REPLICAS)
  -p  Postgres admin password            (required if PG password not in env)
  -k  n8n encryption key                 (auto-generated if omitted)
  -u  Basic auth user (n8n)              (default: admin)
  -s  Basic auth password                (required if basic auth enabled)
  -d  Disable basic auth (not recommended)
  -f  Full path to a .env file to source (optional)
  -h  Show this help text

Environment variables (override CLI):
  N8N_PG_PASSWORD, N8N_ENCRYPTION_KEY, N8N_BASIC_AUTH_USER, N8N_BASIC_AUTH_PASSWORD

EOF
  exit 0
}

# ===== Parse arguments ===== #
BASIC_AUTH_ENABLED=true
ROLLBACK_ON_ERROR=true

while getopts "g:l:e:a:i:c:m:r:x:p:k:u:s:df:h" opt; do
  case $opt in
    g) RESOURCE_GROUP="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    e) ENV_NAME="$OPTARG" ;;
    a) APP_NAME="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    c) CPU="$OPTARG" ;;
    m) MEMORY="$OPTARG" ;;
    r) MIN_REPLICAS="$OPTARG" ;;
    x) MAX_REPLICAS="$OPTARG" ;;
    p) PG_PASSWORD="$OPTARG" ;;
    k) N8N_ENCRYPTION_KEY="$OPTARG" ;;
    u) BASIC_AUTH_USER="$OPTARG" ;;
    s) BASIC_AUTH_PASSWORD="$OPTARG" ;;
    d) BASIC_AUTH_ENABLED=false ;;
    f) ENV_FILE="$OPTARG" ;;
    h) show_help ;;
    *) die "Unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

# ===== Source optional .env file ===== #
if [[ -n "${ENV_FILE:-}" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    die "Provided env file '$ENV_FILE' not found"
  fi
fi

# ===== Set defaults if not already defined ===== #
RESOURCE_GROUP="${RESOURCE_GROUP:-$DEFAULT_RG}"
LOCATION="${LOCATION:-$DEFAULT_LOCATION}"
ENV_NAME="${ENV_NAME:-$DEFAULT_ENV}"
APP_NAME="${APP_NAME:-$DEFAULT_APP}"

# Ensure local image is available (build if missing) BEFORE we start touching Azure resources.
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"
ensure_local_image "$IMAGE"

CPU="${CPU:-$DEFAULT_CPU}"
MEMORY="${MEMORY:-$DEFAULT_MEMORY}"
MIN_REPLICAS="${MIN_REPLICAS:-$DEFAULT_MIN_REPLICAS}"
MAX_REPLICAS="${MAX_REPLICAS:-$DEFAULT_MAX_REPLICAS}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
PG_SERVER_NAME="${PG_SERVER_NAME:-$DEFAULT_PG_SERVER}"
PG_DB="${PG_DB:-$DEFAULT_PG_DB}"
PG_ADMIN_USER="${PG_ADMIN_USER:-azureuser}"  # cannot be "postgres" for Flexible Server
PG_VERSION="${PG_VERSION:-$DEFAULT_PG_VERSION}"
PG_SKU="${PG_SKU:-$DEFAULT_PG_SKU}"
PG_PASSWORD="${PG_PASSWORD:-${N8N_PG_PASSWORD:-}}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(uuidgen | tr -d '-') }"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-${N8N_BASIC_AUTH_PASSWORD:-}}"

# ===== Validate required inputs ===== #
if [[ -z "$PG_PASSWORD" ]]; then
  die "Postgres admin password is required. Use -p or set N8N_PG_PASSWORD env var."
fi
if [[ "$BASIC_AUTH_ENABLED" == "true" && -z "$BASIC_AUTH_PASSWORD" ]]; then
  die "Basic auth password required (option -s) or disable basic auth with -d."
fi

# ===== Confirm Azure CLI is available ===== #
command -v az >/dev/null || die "Azure CLI not found. Install from https://aka.ms/azcli."

# ===== Ensure containerapp extension installed ===== #
if ! az extension show --name containerapp &>/dev/null; then
  log "Installing Azure CLI 'containerapp' extension…"
  az extension add --name containerapp --upgrade
else
  # Ensure latest version for new flags
  az extension update --name containerapp --yes || true
fi

# ===== Create or reuse resource group ===== #
RG_CREATED=false
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  log "Resource group $RESOURCE_GROUP already exists – reusing."
else
  log "Creating resource group $RESOURCE_GROUP in $LOCATION…"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null
  RG_CREATED=true
fi

# ===== Create or reuse Log Analytics workspace ===== #
WORKSPACE_NAME="${ENV_NAME}-logs"
if az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" &>/dev/null; then
  log "Log Analytics workspace $WORKSPACE_NAME exists – reusing."
else
  log "Creating Log Analytics workspace $WORKSPACE_NAME…"
  az monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" >/dev/null
fi
LOG_ID=$(az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" --query customerId -o tsv)
LOG_KEY=$(az monitor log-analytics workspace get-shared-keys -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" --query primarySharedKey -o tsv)

# ===== Create or reuse Container Apps environment ===== #
if az containerapp env show -g "$RESOURCE_GROUP" -n "$ENV_NAME" &>/dev/null; then
  log "Container Apps environment $ENV_NAME exists – reusing."
else
  log "Creating Container Apps environment $ENV_NAME…"
  az containerapp env create \
    -g "$RESOURCE_GROUP" -n "$ENV_NAME" \
    --location "$LOCATION" \
    --logs-workspace-id "$LOG_ID" \
    --logs-workspace-key "$LOG_KEY" >/dev/null
fi

# ===== Create or reuse Postgres Flexible Server ===== #
if az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" &>/dev/null; then
  log "Postgres server $PG_SERVER_NAME exists – reusing."
else
  log "Creating Postgres Flexible Server $PG_SERVER_NAME (sku $PG_SKU)…"
  az postgres flexible-server create \
    --name "$PG_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --admin-user "$PG_ADMIN_USER" \
    --admin-password "$PG_PASSWORD" \
    --sku-name "$PG_SKU" \
    --version "$PG_VERSION" \
    --storage-size 32 \
    --yes >/dev/null

  # Allow Azure services (including Container Apps) to connect
  log "Creating firewall rule to allow Azure services to access Postgres…"
  az postgres flexible-server firewall-rule create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PG_SERVER_NAME" \
    --rule-name AllowAzureServices \
    --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 >/dev/null
fi

# Ensure database exists
if az postgres flexible-server db show -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" -d "$PG_DB" &>/dev/null; then
  log "Database $PG_DB exists – reusing."
else
  log "Creating database $PG_DB…"
  az postgres flexible-server db create -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" -d "$PG_DB" >/dev/null
fi

PG_FQDN="$(az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" --query fullyQualifiedDomainName -o tsv)"

# ===== Prepare secrets for Container App ===== #
SECRET_ENCRYPTION_KEY="encryption-key"
SECRET_PG_PASSWORD="pg-password"
SECRET_BASIC_AUTH_PW="basic-auth-password"

SECRETS=("$SECRET_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY" "$SECRET_PG_PASSWORD=$PG_PASSWORD")
ENV_VARS=("DB_TYPE=postgresdb" "DB_POSTGRESDB_HOST=$PG_FQDN" "DB_POSTGRESDB_PORT=5432" "DB_POSTGRESDB_DATABASE=$PG_DB" "DB_POSTGRESDB_USER=$PG_ADMIN_USER@$PG_SERVER_NAME" "DB_POSTGRESDB_PASSWORD=secretref:$SECRET_PG_PASSWORD" "N8N_ENCRYPTION_KEY=secretref:$SECRET_ENCRYPTION_KEY" "GENERIC_TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')" "WEBHOOK_URL=https://$APP_NAME.$LOCATION.azurecontainerapps.io/" )

if [[ "$BASIC_AUTH_ENABLED" == "true" ]]; then
  SECRETS+=("$SECRET_BASIC_AUTH_PW=$BASIC_AUTH_PASSWORD")
  ENV_VARS+=("N8N_BASIC_AUTH_ACTIVE=true" "N8N_BASIC_AUTH_USER=$BASIC_AUTH_USER" "N8N_BASIC_AUTH_PASSWORD=secretref:$SECRET_BASIC_AUTH_PW")
else
  ENV_VARS+=("N8N_BASIC_AUTH_ACTIVE=false")
fi

# Convert arrays to CLI args
SECRETS_ARGS=()
for s in "${SECRETS[@]}"; do SECRETS_ARGS+=(--secrets "$s"); done
ENV_ARGS=()
for v in "${ENV_VARS[@]}"; do ENV_ARGS+=(--env-vars "$v"); done

# ===== Create or update Container App ===== #
if az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" &>/dev/null; then
  log "Updating existing Container App $APP_NAME…"
  az containerapp update \
    -g "$RESOURCE_GROUP" -n "$APP_NAME" \
    --image "$IMAGE" \
    --cpu "$CPU" --memory "$MEMORY" \
    --min-replicas "$MIN_REPLICAS" --max-replicas "$MAX_REPLICAS" \
    "${SECRETS_ARGS[@]}" "${ENV_ARGS[@]}" >/dev/null
else
  log "Creating Container App $APP_NAME…"
  az containerapp create \
    -g "$RESOURCE_GROUP" -n "$APP_NAME" \
    --environment "$ENV_NAME" \
    --location "$LOCATION" \
    --image "$IMAGE" \
    --target-port 5678 \
    --ingress external \
    --cpu "$CPU" --memory "$MEMORY" \
    --min-replicas "$MIN_REPLICAS" --max-replicas "$MAX_REPLICAS" \
    "${SECRETS_ARGS[@]}" "${ENV_ARGS[@]}" >/dev/null
fi

APP_URL="$(az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query properties.latestRevisionFqdn -o tsv)"
log "Deployment successful!"
log "n8n is now accessible at: https://$APP_URL"
if [[ "$BASIC_AUTH_ENABLED" == "true" ]]; then
  log "Login with user '$BASIC_AUTH_USER' and the password you supplied."
fi

log "Tip: set a custom domain & free HTTPS via: az containerapp ingress custom-domain enable …" 