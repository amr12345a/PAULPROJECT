#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ib-trade-executor"
SERVICE_NAME="ib-trade-executor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_USER="${SUDO_USER:-$USER}"

if [ -z "${APP_DIR}" ] || [ "${APP_DIR}" = "/" ]; then
  echo "Refusing to use APP_DIR='${APP_DIR}'. Set APP_DIR to a non-root application directory."
  exit 1
fi

sudo mkdir -p "$APP_DIR"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$APP_DIR"

# Update only Python service files.
cp "$SCRIPT_DIR/main.py" "$APP_DIR/main.py"
cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/requirements.txt"
cp "$SCRIPT_DIR/ib-trade-executor.service" "$APP_DIR/ib-trade-executor.service"

if [ -f "$SCRIPT_DIR/.env.example" ] && [ ! -f "$APP_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$APP_DIR/.env"
  echo "Created missing .env from .env.example at $APP_DIR/.env"
fi

cd "$APP_DIR"

if [ ! -d .venv ]; then
  echo ".venv not found; creating virtual environment"
  python3 -m venv .venv
fi

source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

sudo cp ib-trade-executor.service "/etc/systemd/system/${SERVICE_NAME}.service"
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
sudo systemctl status "$SERVICE_NAME" --no-pager

echo "Python service update complete."
