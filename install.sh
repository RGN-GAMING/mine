#!/usr/bin/env bash
# EVM V1 NO-LXC / NO-KVM controller installer
set -Eeuo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
step(){ echo -e "${GRN}[+]${NC} $*"; }
warn(){ echo -e "${YEL}[!]${NC} $*"; }
fail(){ echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/bot.py" ]] || fail "bot.py not found next to install.sh"

if ! command -v apt-get >/dev/null 2>&1; then
  fail "This installer supports Ubuntu/Debian (apt-get) only."
fi

step "Installing Python runtime and basic utilities (no LXC/LXD/KVM packages)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 python3-venv python3-pip python3-dev build-essential ca-certificates curl git

step "Creating EVM V1 application directory..."
install -d -m 700 /opt/evm-v1
install -m 600 "$SCRIPT_DIR/bot.py" /opt/evm-v1/bot.py

step "Creating Python virtual environment and installing dependencies..."
python3 -m venv /opt/evm-v1/venv
/opt/evm-v1/venv/bin/python -m pip install --upgrade pip
/opt/evm-v1/venv/bin/python -m pip install discord.py python-dotenv requests
/opt/evm-v1/venv/bin/python -m py_compile /opt/evm-v1/bot.py

ENV_FILE=/opt/evm-v1/.env
if [[ -f "$SCRIPT_DIR/.env" && ! -f "$ENV_FILE" ]]; then
  install -m 600 "$SCRIPT_DIR/.env" "$ENV_FILE"
fi
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

read -rsp "Discord Bot Token: " TOKEN; echo
[[ -n "$TOKEN" ]] || fail "Discord token cannot be empty."
while true; do
  read -rp "Main Admin Discord User ID: " ADMIN_ID
  [[ "$ADMIN_ID" =~ ^[0-9]{15,22}$ ]] && break
  warn "Enter a valid numeric Discord user ID."
done
read -rp "VPS User Role ID (Enter to skip): " ROLE_ID
if [[ -n "$ROLE_ID" && ! "$ROLE_ID" =~ ^[0-9]{15,22}$ ]]; then fail "Role ID must be numeric or blank."; fi
read -rp "Command prefix [1]: " PREFIX
PREFIX="${PREFIX:-1}"
[[ ${#PREFIX} -le 5 && "$PREFIX" != *[[:space:]]* && "$PREFIX" != /* ]] || fail "Invalid prefix. Use 1-5 characters without spaces."

TMP_ENV="$(mktemp)"
# Preserve unrelated optional settings but replace values controlled by this installer.
grep -vE '^(DISCORD_TOKEN|MAIN_ADMIN_ID|VPS_USER_ROLE_ID|BOT_PREFIX|CONTROLLER_ONLY_MODE|REMOTE_NODE_ONLY|BOT_VERSION)=' "$ENV_FILE" > "$TMP_ENV" || true
{
  printf 'DISCORD_TOKEN=%s\n' "$TOKEN"
  printf 'MAIN_ADMIN_ID=%s\n' "$ADMIN_ID"
  printf 'VPS_USER_ROLE_ID=%s\n' "${ROLE_ID:-0}"
  printf 'BOT_PREFIX=%s\n' "$PREFIX"
  printf 'CONTROLLER_ONLY_MODE=true\nREMOTE_NODE_ONLY=true\nBOT_VERSION=1.0-NO-LXC-NO-KVM\n'
} >> "$TMP_ENV"
install -m 600 "$TMP_ENV" "$ENV_FILE"
rm -f "$TMP_ENV"
unset TOKEN

step "Creating systemd service..."
cat > /etc/systemd/system/evm-v1.service <<'UNIT'
[Unit]
Description=EVM V1 Discord VPS Controller (No LXC / No KVM)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evm-v1
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/opt/evm-v1/.env
ExecStart=/opt/evm-v1/venv/bin/python /opt/evm-v1/bot.py
Restart=on-failure
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable evm-v1.service
systemctl restart evm-v1.service
sleep 2
if systemctl is-active --quiet evm-v1.service; then
  step "EVM V1 service is running."
else
  journalctl -u evm-v1.service -n 60 --no-pager || true
  fail "Service failed to start. Check the logs above."
fi

echo
echo "Install complete."
echo "Status : systemctl status evm-v1"
echo "Logs   : journalctl -u evm-v1 -f"
echo "Restart: systemctl restart evm-v1"
echo
echo "Mode: controller-only. Local VPS creation is intentionally disabled."
echo "To deploy real VPS instances, configure a separate supported remote node/backend first."
