#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ib-trade-executor"
SERVICE_NAME="ib-trade-executor"

sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx

sudo mkdir -p "$APP_DIR"
sudo chown -R "$USER":"$USER" "$APP_DIR"

echo "Copy project files into $APP_DIR before continuing if needed."
cd "$APP_DIR"

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
