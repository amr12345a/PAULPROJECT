#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ib-trade-executor"
SERVICE_NAME="ib-trade-executor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx

sudo mkdir -p "$APP_DIR"
sudo chown -R "$USER":"$USER" "$APP_DIR"

# Sync project files from where this script lives into APP_DIR.
cp "$SCRIPT_DIR/main.py" "$APP_DIR/main.py"
cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/requirements.txt"
cp "$SCRIPT_DIR/.env.example" "$APP_DIR/.env.example"
cp "$SCRIPT_DIR/ib-trade-executor.service" "$APP_DIR/ib-trade-executor.service"
cp "$SCRIPT_DIR/ib-trade-executor.nginx" "$APP_DIR/ib-trade-executor.nginx"
cp "$SCRIPT_DIR/README.md" "$APP_DIR/README.md"

cd "$APP_DIR"

if [ ! -f requirements.txt ]; then
  echo "requirements.txt not found in $APP_DIR"
  echo "Run this script from your project directory, or place project files in $APP_DIR first."
  exit 1
fi

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from template. Please edit it now: $APP_DIR/.env"
fi

sudo cp ib-trade-executor.service /etc/systemd/system/${SERVICE_NAME}.service
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
sudo systemctl status "$SERVICE_NAME" --no-pager

sudo cp ib-trade-executor.nginx /etc/nginx/sites-available/ib-trade-executor
sudo ln -sf /etc/nginx/sites-available/ib-trade-executor /etc/nginx/sites-enabled/ib-trade-executor
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx
sudo systemctl status nginx --no-pager
