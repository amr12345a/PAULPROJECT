#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ninja-trader-executor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_USER="${SUDO_USER:-$USER}"
DEPLOY_HOME="$(eval echo "~${DEPLOY_USER}")"
NT_DIR="/opt/ninjatrader"
NT_INSTALLER_URL="${NT_INSTALLER_URL:-}"

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
  dbus-x11 \
  tigervnc-standalone-server \
  tigervnc-common \
  xfce4 \
  xfce4-goodies \
  wget \
  unzip \
  ca-certificates

# Wine packaging varies by Ubuntu release; install with fallbacks instead of failing hard.
if dpkg --print-architecture | grep -q '^amd64$'; then
  sudo dpkg --add-architecture i386 || true
  sudo apt update
fi

if apt-cache show wine >/dev/null 2>&1; then
  sudo apt install -y wine || true
fi

if apt-cache show wine64 >/dev/null 2>&1; then
  sudo apt install -y wine64 || true
fi

if apt-cache show wine32 >/dev/null 2>&1; then
  sudo apt install -y wine32 || true
elif apt-cache show libwine >/dev/null 2>&1; then
  # Some distros replace wine32 with libwine.
  sudo apt install -y libwine || true
fi

if apt-cache show winetricks >/dev/null 2>&1; then
  sudo apt install -y winetricks || true
fi

sudo mkdir -p "$APP_DIR"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$APP_DIR"

sudo mkdir -p "$NT_DIR"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$NT_DIR"

# Sync project files from where this script lives into APP_DIR.
cp "$SCRIPT_DIR/main.py" "$APP_DIR/main.py"
cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/requirements.txt"
cp "$SCRIPT_DIR/.env.example" "$APP_DIR/.env.example"
cp "$SCRIPT_DIR/ninja-trader-executor.service" "$APP_DIR/ninja-trader-executor.service"
cp "$SCRIPT_DIR/ninja-trader-executor.nginx" "$APP_DIR/ninja-trader-executor.nginx"
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

APP_PORT="$(grep -E '^PORT=' .env | tail -n 1 | cut -d '=' -f2 | tr -d '[:space:]' || true)"
if [ -z "$APP_PORT" ]; then
  APP_PORT="80"
fi

sudo cp ninja-trader-executor.service /etc/systemd/system/ninja-trader-executor.service

sudo -u "$DEPLOY_USER" mkdir -p "$DEPLOY_HOME/.vnc"
if [ ! -f "$DEPLOY_HOME/.vnc/passwd" ]; then
  printf "%s\n" "$VNC_PASSWORD" | sudo -u "$DEPLOY_USER" vncpasswd -f > "$DEPLOY_HOME/.vnc/passwd"
  sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_HOME/.vnc/passwd"
  chmod 600 "$DEPLOY_HOME/.vnc/passwd"
fi

cat > "$DEPLOY_HOME/.vnc/xstartup" <<'EOF'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session startxfce4
elif command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- startxfce4
else
  exec startxfce4
fi
EOF
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_HOME/.vnc/xstartup"
chmod +x "$DEPLOY_HOME/.vnc/xstartup"

# Create NinjaTrader launcher wrapper
NT_LAUNCHER_WRAPPER="${NT_DIR}/run-ninjatrader.sh"
cat > "$NT_LAUNCHER_WRAPPER" <<'NTEOF'
#!/usr/bin/env bash
set -euo pipefail
export HOME="${DEPLOY_HOME}"
export USER="${DEPLOY_USER}"
export LOGNAME="${DEPLOY_USER}"
export DISPLAY=":1"
export WINEPREFIX="${NT_DIR}/.wine"

# Start NinjaTrader via Wine (if installed as Windows executable)
if [ -f "${NT_DIR}/NinjaTrader 8/bin/NinjaTrader.exe" ]; then
  exec wine "${NT_DIR}/NinjaTrader 8/bin/NinjaTrader.exe" "$@"
elif [ -f "${NT_DIR}/ninjatrader" ]; then
  # Or if native binary exists
  exec "${NT_DIR}/ninjatrader" "$@"
else
  echo "NinjaTrader executable not found in ${NT_DIR}"
  sleep 300
  exit 1
fi
NTEOF

chmod +x "$NT_LAUNCHER_WRAPPER"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$NT_LAUNCHER_WRAPPER"

# Download NinjaTrader installer if URL provided
if [ -n "$NT_INSTALLER_URL" ] && [ ! -d "${NT_DIR}/NinjaTrader 8" ] && [ ! -f "${NT_DIR}/ninjatrader" ]; then
  installer_path="/tmp/ninjatrader-installer"
  if [ ! -f "$installer_path" ]; then
    echo "Downloading NinjaTrader installer from: $NT_INSTALLER_URL"
    wget -O "$installer_path" "$NT_INSTALLER_URL"
  fi
  
  chmod +x "$installer_path"
  echo "Running NinjaTrader installer..."
  
  if sudo -u "$DEPLOY_USER" bash "$installer_path" -q -dir "$NT_DIR" 2>/dev/null || [ -d "${NT_DIR}" ]; then
    echo "NinjaTrader prepared in ${NT_DIR}"
  fi
fi

# Create NinjaTrader systemd service
sudo tee /etc/systemd/system/ninjatrader.service >/dev/null <<NTEOF
[Unit]
Description=NinjaTrader 8 Platform
After=network.target tigervnc.service
Requires=tigervnc.service

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${NT_DIR}
Environment=HOME=${DEPLOY_HOME}
Environment=DISPLAY=${VNC_DISPLAY}
Environment=WINEPREFIX=${NT_DIR}/.wine
ExecStart=${NT_LAUNCHER_WRAPPER}
Restart=always
RestartSec=5
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
NTEOF

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

sudo systemctl daemon-reload
sudo systemctl enable ninja-trader-executor
sudo systemctl restart ninja-trader-executor
sudo systemctl status ninja-trader-executor --no-pager
sudo systemctl enable tigervnc
sudo systemctl restart tigervnc
sudo systemctl status tigervnc --no-pager

sudo systemctl daemon-reload
sudo systemctl enable ninjatrader
sudo systemctl restart ninjatrader
sudo systemctl status ninjatrader --no-pager

echo "=========================================="
echo "Deployment complete!"
echo "=========================================="
echo "VNC Access:"
echo "  Address: ${HOSTNAME}:5901 (or <ip>:5901)"
echo "  Password: Set in VNC_PASSWORD (.env)"
echo "  Geometry: ${VNC_GEOMETRY}"
echo ""
echo "NinjaTrader:"
echo "  Location: ${NT_DIR}"
echo "  Launcher: ${NT_LAUNCHER_WRAPPER}"
echo "  Service: ninjatrader (systemd)"
echo "  Display: ${VNC_DISPLAY}"
echo ""
echo "FastAPI Signal Bridge:"
echo "  Health: curl http://localhost/health"
echo "  Trade endpoint: POST http://localhost/trade"
echo ""
echo "View service logs:"
echo "  journalctl -u ninjatrader -f"
echo "  journalctl -u ninja-trader-executor -f"
echo "=========================================="

if [ "$APP_PORT" = "80" ]; then
  echo "APP port is 80; skipping nginx reverse-proxy setup to avoid port conflict."
  sudo systemctl disable --now nginx || true
else
  sudo cp ninja-trader-executor.nginx /etc/nginx/sites-available/ninja-trader-executor
  sudo ln -sf /etc/nginx/sites-available/ninja-trader-executor /etc/nginx/sites-enabled/ninja-trader-executor
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
  sudo systemctl enable nginx
  sudo systemctl restart nginx
  sudo systemctl status nginx --no-pager
fi
