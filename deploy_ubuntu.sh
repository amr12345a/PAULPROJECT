#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ib-trade-executor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_USER="${SUDO_USER:-$USER}"
DEPLOY_HOME="$(eval echo "~${DEPLOY_USER}")"

IB_GATEWAY_DIR="/opt/ibgateway"
IB_GATEWAY_INSTALLER_URL="${IB_GATEWAY_INSTALLER_URL:-https://download2.interactivebrokers.com/installers/ibgateway/latest-standalone/ibgateway-latest-standalone-linux-x64.sh}"
IB_GATEWAY_LAUNCHER="${IB_GATEWAY_LAUNCHER:-}"

VNC_DISPLAY=":1"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-change-me-now}"

if [ -z "${APP_DIR}" ] || [ "${APP_DIR}" = "/" ]; then
  echo "Refusing to use APP_DIR='${APP_DIR}'. Set APP_DIR to a non-root application directory."
  exit 1
fi

sudo apt update
sudo apt install -y \
  python3 \
  python3-venv \
  nginx \
  default-jre \
  xvfb \
  tigervnc-standalone-server \
  tigervnc-common \
  xfce4 \
  xfce4-goodies \
  wget \
  unzip \
  ca-certificates

sudo mkdir -p "$APP_DIR"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$APP_DIR"

sudo mkdir -p "$IB_GATEWAY_DIR"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$IB_GATEWAY_DIR"

# Sync project files from where this script lives into APP_DIR.
cp "$SCRIPT_DIR/main.py" "$APP_DIR/main.py"
cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/requirements.txt"
cp "$SCRIPT_DIR/.env.example" "$APP_DIR/.env.example"
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

if [ -n "$IB_GATEWAY_INSTALLER_URL" ]; then
  installer_path="/tmp/ibgateway-installer"
  echo "Downloading IB Gateway installer from: $IB_GATEWAY_INSTALLER_URL"
  wget -O "$installer_path" "$IB_GATEWAY_INSTALLER_URL"

  # Most IB Gateway installers are install4j-based and support -q and -dir.
  if bash "$installer_path" -q -dir "$IB_GATEWAY_DIR"; then
    echo "IB Gateway installed into $IB_GATEWAY_DIR"
  else
    echo "Automatic IB Gateway install failed. Install manually into $IB_GATEWAY_DIR and rerun."
  fi
else
  echo "IB_GATEWAY_INSTALLER_URL not set; skipping automatic IB Gateway download/install."
  echo "Set IB_GATEWAY_INSTALLER_URL and rerun to install IB Gateway automatically."
fi

if [ -z "$IB_GATEWAY_LAUNCHER" ]; then
  detected_launcher="$(find "$IB_GATEWAY_DIR" -maxdepth 4 -type f \( -name ibgateway -o -name ibgateway.sh -o -name gatewaystart.sh \) 2>/dev/null | head -n 1 || true)"
  if [ -n "$detected_launcher" ]; then
    IB_GATEWAY_LAUNCHER="$detected_launcher"
  fi
fi

sudo -u "$DEPLOY_USER" mkdir -p "$DEPLOY_HOME/.vnc"
printf "%s\n" "$VNC_PASSWORD" | sudo -u "$DEPLOY_USER" vncpasswd -f > "$DEPLOY_HOME/.vnc/passwd"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_HOME/.vnc/passwd"
chmod 600 "$DEPLOY_HOME/.vnc/passwd"

cat > "$DEPLOY_HOME/.vnc/xstartup" <<'EOF'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_HOME/.vnc/xstartup"
chmod +x "$DEPLOY_HOME/.vnc/xstartup"

sudo tee /etc/systemd/system/tigervnc.service >/dev/null <<EOF
[Unit]
Description=TigerVNC Server on ${VNC_DISPLAY}
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
ExecStartPre=-/usr/bin/vncserver -kill ${VNC_DISPLAY}
ExecStartPre=-/bin/rm -f /tmp/.X11-unix/X${VNC_DISPLAY#:} /tmp/.X${VNC_DISPLAY#:}-lock
ExecStart=/usr/bin/vncserver ${VNC_DISPLAY} -fg -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} -localhost no -xstartup ${DEPLOY_HOME}/.vnc/xstartup
ExecStop=/usr/bin/vncserver -kill ${VNC_DISPLAY}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

if [ -n "$IB_GATEWAY_LAUNCHER" ] && [ -f "$IB_GATEWAY_LAUNCHER" ]; then
  sudo tee /etc/systemd/system/ibgateway.service >/dev/null <<EOF
[Unit]
Description=Interactive Brokers Gateway
After=network.target tigervnc.service
Requires=tigervnc.service

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${IB_GATEWAY_DIR}
Environment=DISPLAY=${VNC_DISPLAY}
ExecStart=${IB_GATEWAY_LAUNCHER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable tigervnc
  sudo systemctl restart tigervnc
  sudo systemctl enable ibgateway
  sudo systemctl restart ibgateway
  sudo systemctl status tigervnc --no-pager
  sudo systemctl status ibgateway --no-pager
else
  echo "IB Gateway launcher not found. Set IB_GATEWAY_LAUNCHER to the executable path and rerun."
  sudo systemctl daemon-reload
  sudo systemctl enable tigervnc
  sudo systemctl restart tigervnc
  sudo systemctl status tigervnc --no-pager
fi

sudo cp ib-trade-executor.nginx /etc/nginx/sites-available/ib-trade-executor
sudo ln -sf /etc/nginx/sites-available/ib-trade-executor /etc/nginx/sites-enabled/ib-trade-executor
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx
sudo systemctl status nginx --no-pager
