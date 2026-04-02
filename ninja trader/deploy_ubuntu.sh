#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ninja-trader-executor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_USER="${SUDO_USER:-$USER}"
DEPLOY_HOME="$(eval echo "~${DEPLOY_USER}")"
NT_DIR="/opt/ninjatrader"
NT_INSTALLER_URL="${NT_INSTALLER_URL:-https://download.ninjatrader.com/}"

VNC_DISPLAY=":1"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-change-me-now}"

if [ -z "${APP_DIR}" ] || [ "${APP_DIR}" = "/" ]; then
  echo "Refusing to use APP_DIR='${APP_DIR}'. Set APP_DIR to a non-root application directory."
  exit 1
fi

# Recover from interrupted package operations before installing dependencies.
sudo dpkg --configure -a || true
sudo apt --fix-broken install -y || true

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
  xdg-utils \
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

# Create a self-contained launcher helper inside the NinjaTrader folder.
NT_LAUNCHER_WRAPPER="${NT_DIR}/run-ninjatrader.sh"
cat > "$NT_LAUNCHER_WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

NT_DIR="${NT_DIR:-/opt/ninjatrader}"
export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/home/ubuntu}"
export USER="${USER:-ubuntu}"
export LOGNAME="${LOGNAME:-ubuntu}"
export WINEARCH="${WINEARCH:-win64}"
export WINEPREFIX="${WINEPREFIX:-${NT_DIR}/.wine}"

WINE_BIN="$(command -v wine64 2>/dev/null || command -v wine 2>/dev/null || true)"
if [ -z "$WINE_BIN" ]; then
  echo "wine is not installed. Install wine, wine64, and the needed 32-bit support, then retry."
  exit 1
fi

mkdir -p "$WINEPREFIX"

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  "$WINE_BIN" wineboot -u >/tmp/ninjatrader-wineboot.log 2>&1 || {
    cat /tmp/ninjatrader-wineboot.log
    echo "Wine prefix initialization failed. Check that wine and its dependencies are installed."
    exit 1
  }
fi

NT_EXE="${NT_DIR}/NinjaTrader 8/bin/NinjaTrader.exe"
NT_INSTALLER_MSI="${NT_DIR}/NinjaTraderInstaller.msi"
NT_INSTALLER_EXE="${NT_DIR}/NinjaTraderInstaller.exe"

if [ -f "$NT_EXE" ]; then
  exec "$WINE_BIN" "$NT_EXE" "$@"
fi

if [ -f "$NT_INSTALLER_MSI" ]; then
  exec "$WINE_BIN" msiexec /i "$NT_INSTALLER_MSI" "$@"
fi

if [ -f "$NT_INSTALLER_EXE" ]; then
  exec "$WINE_BIN" "$NT_INSTALLER_EXE" "$@"
fi

echo "NinjaTrader installer or executable not found in ${NT_DIR}"
echo "Put the .msi in that folder and run it from VNC."
sleep 300
exit 1
EOF
chmod +x "$NT_LAUNCHER_WRAPPER"
sudo chown "$DEPLOY_USER":"$DEPLOY_USER" "$NT_LAUNCHER_WRAPPER"

# If URL points directly to an MSI or EXE, pre-download it into the VNC-accessible directory.
if [ -n "$NT_INSTALLER_URL" ] && echo "$NT_INSTALLER_URL" | grep -Eiq '\.(msi|exe)(\?.*)?$'; then
  installer_ext="$(echo "$NT_INSTALLER_URL" | grep -Eoi '\.(msi|exe)' | tr -d '.')"
  installer_file="${NT_DIR}/NinjaTraderInstaller.${installer_ext}"
  if [ ! -f "$installer_file" ]; then
    echo "Downloading NinjaTrader installer from: $NT_INSTALLER_URL"
    wget -O "$installer_file" "$NT_INSTALLER_URL"
    chown "$DEPLOY_USER":"$DEPLOY_USER" "$installer_file"
  fi
fi

sudo tee /etc/systemd/system/tigervnc.service >/dev/null <<EOF
[Unit]
Description=TigerVNC Server on ${VNC_DISPLAY}
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
ExecStartPre=/bin/bash -lc '/usr/bin/vncserver -list | grep -q "${VNC_DISPLAY}" && /usr/bin/vncserver -kill ${VNC_DISPLAY} || true'
ExecStartPre=-/bin/rm -f /tmp/.X11-unix/X${VNC_DISPLAY#:} /tmp/.X${VNC_DISPLAY#:}-lock
ExecStart=/usr/bin/vncserver ${VNC_DISPLAY} -fg -autokill no -AlwaysShared -DisconnectClients=0 -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} -localhost no -xstartup ${DEPLOY_HOME}/.vnc/xstartup
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

echo "NinjaTrader installer file is available in: ${NT_DIR}"
echo "Open VNC and run the .msi installer manually from there."

echo "=========================================="
echo "Deployment complete!"
echo "=========================================="
echo "VNC Access:"
echo "  Address: ${HOSTNAME}:5901 (or <ip>:5901)"
echo "  Password: Set in VNC_PASSWORD (.env)"
echo "  Geometry: ${VNC_GEOMETRY}"
echo ""
echo "NinjaTrader:"
echo "  Direct installer URL: ${NT_INSTALLER_URL}"
echo "  Installer directory: ${NT_DIR}"
echo "  Display: ${VNC_DISPLAY}"
echo ""
echo "FastAPI Signal Bridge:"
echo "  Health: curl http://localhost/health"
echo "  Trade endpoint: POST http://localhost/trade"
echo ""
echo "View service logs:"
echo "  journalctl -u tigervnc -f"
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
