#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "error: $1" >&2; exit 1; }

[ -f .env ] || fail ".env not found in $SCRIPT_DIR"
set -a; . ./.env; set +a

CHAIN_ID="${CHAIN_ID:?CHAIN_ID not set}"
MONIKER="${MONIKER:-nexus-node}"
COSMOS_IMAGE="${COSMOS_IMAGE:?COSMOS_IMAGE not set}"
PERSISTENT_PEERS="${PERSISTENT_PEERS:?PERSISTENT_PEERS not set}"

case "${DATA_BASE:-./data}" in
  /*) DATA_BASE_ABS="${DATA_BASE}" ;;
  *)  DATA_BASE_ABS="${SCRIPT_DIR}/${DATA_BASE#./}" ;;
esac

CONFIG_DIR="${DATA_BASE_ABS}/config"
JWT_DIR="${DATA_BASE_ABS}/jwt"
JWT_FILE="${JWT_DIR}/jwt.hex"
COSMOS_HOME="${DATA_BASE_ABS}/cosmos-home"

command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
[ -f "${CONFIG_DIR}/cosmos/genesis.json" ] || fail "missing ${CONFIG_DIR}/cosmos/genesis.json"

echo "==> Generating JWT secret"
mkdir -p "$JWT_DIR"
if [ -s "$JWT_FILE" ]; then
  echo "    already present at ${JWT_FILE}"
else
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$JWT_FILE"
  echo "    wrote ${JWT_FILE}"
fi
chmod 644 "$JWT_FILE"

echo "==> Initialising cosmos-home"
mkdir -p "$COSMOS_HOME"
if [ -f "${COSMOS_HOME}/config/priv_validator_key.json" ]; then
  echo "    already initialised, skipping nexusd init"
else
  docker run --rm \
    --network host \
    --user "$(id -u):$(id -g)" \
    -v "${COSMOS_HOME}:/cosmos-home" \
    -v "${CONFIG_DIR}/cosmos:/chain-config:ro" \
    -v "${JWT_DIR}:/jwt:ro" \
    -e EVM_ENGINE_JWT_SECRET_PATH=/jwt/jwt.hex \
    -e NEXUS_CONFIG_PATH=/chain-config/nexus-config.cosmos.yaml \
    --entrypoint nexusd \
    "${COSMOS_IMAGE}" \
    init "${MONIKER}" --chain-id "${CHAIN_ID}" --home /cosmos-home >/dev/null
  echo "    initialised with moniker '${MONIKER}'"
fi

echo "==> Installing canonical genesis and chain config"
cp "${CONFIG_DIR}/cosmos/genesis.json"             "${COSMOS_HOME}/config/genesis.json"
cp "${CONFIG_DIR}/cosmos/nexus-config.cosmos.yaml" "${COSMOS_HOME}/config/nexus-config.cosmos.yaml"

echo "==> Patching peers and gas price"
sed -i \
  -e "s|^persistent_peers = .*|persistent_peers = \"${PERSISTENT_PEERS}\"|" \
  -e 's|^seeds = .*|seeds = ""|' \
  "${COSMOS_HOME}/config/config.toml"
sed -i 's|^minimum-gas-prices = .*|minimum-gas-prices = "0atnex"|' \
  "${COSMOS_HOME}/config/app.toml"

echo
echo "Init complete. Start the node with:"
echo "    docker compose up -d"
