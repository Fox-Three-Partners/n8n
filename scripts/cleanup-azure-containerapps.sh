#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------------
# cleanup-azure-containerapps.sh
# --------------------------------------------------------------------------------------------------
# Reverts the actions performed by deploy-to-azure-containerapps.sh.
# Deletes the Container App, Container Apps environment, PostgreSQL Flexible Server,
# Log Analytics workspace, and optionally the resource group created for n8n.
#
# The script is designed to be:
#   • Idempotent – safe to re-run even if some resources are already gone
#   • Safe – prompts for confirmation before destructive operations (can be suppressed with -y)
#   • Logged – prints each step with timestamps
#
# Usage:
#   ./cleanup-azure-containerapps.sh -g <resource-group> -e <env-name> -a <app-name> \
#       -s <postgres-server> [-y]
#
# Flags & env-vars mirror the deployment script for consistency.
# --------------------------------------------------------------------------------------------------

set -Eeuo pipefail

# ===== Defaults (must match deploy script) ===== #
SCRIPT_NAME=$(basename "$0")
DEFAULT_LOCATION="eastus"   # Only needed if deleting RG
DEFAULT_RG="n8n-rg"
DEFAULT_ENV="n8n-env"
DEFAULT_APP="n8n-app"
DEFAULT_PG_SERVER="n8ndb"
DEFAULT_IMAGE="n8n-local:dev"

# Directory created by build-n8n.mjs
LOCAL_COMPILED_DIR="$(cd "$(dirname "$0")/.." && pwd)/compiled"

# ===== Helper functions ===== #
log() {
  local level="${2:-INFO}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $1"
}

die() {
  log "$1" "ERROR"
  exit 1
}

confirm() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  read -r -p "$1 (y/N): " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

show_help() {
  cat <<EOF
$SCRIPT_NAME – Tear down n8n resources on Azure Container Apps

Options:
  -g  Azure Resource Group name        (default: $DEFAULT_RG)
  -e  Container Apps Environment name  (default: $DEFAULT_ENV)
  -a  Container App name               (default: $DEFAULT_APP)
  -s  PostgreSQL Flexible Server name  (default: $DEFAULT_PG_SERVER)
  -i  Docker image to remove locally   (default: $DEFAULT_IMAGE)
  -y  Assume yes – skip confirmation prompts
  -h  Show this help text

All flags are optional if you used the default names in deployment.
EOF
  exit 0
}

# ===== Parse args ===== #
ASSUME_YES=false
while getopts "g:e:a:s:i:yh" opt; do
  case $opt in
    g) RESOURCE_GROUP="$OPTARG" ;;
    e) ENV_NAME="$OPTARG" ;;
    a) APP_NAME="$OPTARG" ;;
    s) PG_SERVER_NAME="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    y) ASSUME_YES=true ;;
    h) show_help ;;
    *) die "Unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

RESOURCE_GROUP="${RESOURCE_GROUP:-$DEFAULT_RG}"
ENV_NAME="${ENV_NAME:-$DEFAULT_ENV}"
APP_NAME="${APP_NAME:-$DEFAULT_APP}"
PG_SERVER_NAME="${PG_SERVER_NAME:-$DEFAULT_PG_SERVER}"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"

# ===== Ensure Azure CLI present ===== #
command -v az >/dev/null || die "Azure CLI not found. Install it first."

log "Starting cleanup for resource group: $RESOURCE_GROUP"

if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  log "Resource group $RESOURCE_GROUP does not exist – nothing to clean up." "WARN"
  exit 0
fi

# ===== Confirm destructive action ===== #
if ! confirm "This will permanently delete Azure resources related to n8n in RG '$RESOURCE_GROUP'. Continue?"; then
  log "Cleanup aborted by user." "WARN"
  exit 0
fi

# --------------------------------------------------------------------------------------------------
# 1. Delete Container App (if exists)
# --------------------------------------------------------------------------------------------------
if az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" &>/dev/null; then
  log "Deleting Container App $APP_NAME…"
  az containerapp delete -g "$RESOURCE_GROUP" -n "$APP_NAME" --yes >/dev/null || log "Failed to delete Container App" "ERROR"
else
  log "Container App $APP_NAME not found – skipping." "WARN"
fi

# --------------------------------------------------------------------------------------------------
# 2. Delete Container Apps environment (if exists & empty)
# --------------------------------------------------------------------------------------------------
if az containerapp env show -g "$RESOURCE_GROUP" -n "$ENV_NAME" &>/dev/null; then
  # Ensure no remaining apps – environment delete will fail if apps exist
  remaining=$(az containerapp list -g "$RESOURCE_GROUP" --environment "$ENV_NAME" --query "length(@)" -o tsv)
  if [[ "$remaining" -gt 0 ]]; then
    log "Environment $ENV_NAME still has $remaining app(s). Skipping env deletion." "WARN"
  else
    log "Deleting Container Apps environment $ENV_NAME…"
    az containerapp env delete -g "$RESOURCE_GROUP" -n "$ENV_NAME" --yes >/dev/null || log "Failed to delete environment" "ERROR"
  fi
else
  log "Container Apps environment $ENV_NAME not found – skipping." "WARN"
fi

# --------------------------------------------------------------------------------------------------
# 3. Delete PostgreSQL Flexible Server
# --------------------------------------------------------------------------------------------------
if az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" &>/dev/null; then
  log "Deleting PostgreSQL server $PG_SERVER_NAME…"
  az postgres flexible-server delete -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" --yes --no-wait || log "Failed to delete Postgres server" "ERROR"
else
  log "PostgreSQL server $PG_SERVER_NAME not found – skipping." "WARN"
fi

# --------------------------------------------------------------------------------------------------
# 4. Delete Log Analytics workspace (if empty)
# --------------------------------------------------------------------------------------------------
WORKSPACE_NAME="${ENV_NAME}-logs"
if az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" &>/dev/null; then
  log "Deleting Log Analytics workspace $WORKSPACE_NAME…"
  az monitor log-analytics workspace delete -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" --yes >/dev/null || log "Failed to delete workspace" "ERROR"
else
  log "Log Analytics workspace $WORKSPACE_NAME not found – skipping." "WARN"
fi

# --------------------------------------------------------------------------------------------------
# 5. Optionally delete resource group
# --------------------------------------------------------------------------------------------------
if confirm "Delete the entire resource group '$RESOURCE_GROUP'? This removes any remaining resources inside."; then
  log "Deleting resource group $RESOURCE_GROUP…"
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait || log "Failed to delete resource group" "ERROR"
  log "Resource group deletion initiated. It may take several minutes to complete."
else
  log "Resource group deletion skipped. Manual cleanup may be required for residual resources." "WARN"
fi

log "Cleanup script finished."

# ----- Local artifacts cleanup ----- #
remove_local_artifacts "$IMAGE"

# ===== Local cleanup helper ===== #
remove_local_artifacts() {
  local img="$1"

  if [[ -d "$LOCAL_COMPILED_DIR" ]]; then
    if confirm "Delete local compiled output at '$LOCAL_COMPILED_DIR'?"; then
      log "Removing directory $LOCAL_COMPILED_DIR…"
      rm -rf "$LOCAL_COMPILED_DIR" || log "Failed to remove compiled directory" "ERROR"
    fi
  fi

  if docker image inspect "$img" >/dev/null 2>&1; then
    if confirm "Remove local Docker image '$img'?"; then
      log "Removing Docker image $img…"
      docker rmi "$img" >/dev/null 2>&1 || log "Failed to remove image" "ERROR"
    fi
  fi

  # Optionally remove image from ACR
  if [[ "$img" == *.azurecr.io/* ]]; then
    local acr_name="${img%%.*}"
    local repo_tag="${img#*/}" # e.g. repo:tag
    local repo="${repo_tag%%:*}"
    local tag="${repo_tag##*:}"
    if confirm "Delete image '$img' from Azure Container Registry '$acr_name'?"; then
      log "Deleting image from ACR…"
      az acr login --name "$acr_name" >/dev/null 2>&1 || log "Failed to login to ACR" "ERROR"
      az acr repository delete --name "$acr_name" --image "$repo:$tag" --yes >/dev/null || log "Failed to delete image in ACR" "ERROR"
    fi
  fi
} 