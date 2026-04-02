#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ninja-trader-executor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_USER="${SUDO_USER:-$USER}"
DEPLOY_HOME="$(eval echo "~${DEPLOY_USER}")"
NT_DIR="/opt/ninjatrader"
NT_INSTALLER_URL="${NT_INSTALLER_URL:-https://download.ninjatrader.com/}"
NT_INSTALLER_URL="${NT_INSTALLER_URL%$'\r'}"

VNC_DISPLAY=":1"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-change-me-now}"
AUTO_LAUNCH_NINJATRADER="${AUTO_LAUNCH_NINJATRADER:-1}"

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
  xvfb \
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

WINE_PKGS=()
for pkg in wine wine64 wine32 winetricks libwine libwine:i386 libc6:i386; do
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    WINE_PKGS+=("$pkg")
  fi
done

if [ ${#WINE_PKGS[@]} -eq 0 ]; then
  echo "No Wine packages were found in apt repositories on this host."
  echo "Enable Ubuntu repositories (main/universe/multiverse) or WineHQ, then rerun deploy."
  exit 1
fi

sudo apt install -y --install-recommends "${WINE_PKGS[@]}"

if ! command -v wine >/dev/null 2>&1 && ! command -v wine64 >/dev/null 2>&1; then
  echo "Wine installation appears incomplete: neither 'wine' nor 'wine64' is available in PATH."
  exit 1
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
NT_INSTALLER_URL="${NT_INSTALLER_URL:-https://download.ninjatrader.com/}"
export DISPLAY="${DISPLAY:-:1}"

# Avoid hard-coded usernames/home paths; prefer the current user context.
if [ -z "${USER:-}" ]; then
  export USER="$(id -un)"
fi
if [ -z "${LOGNAME:-}" ]; then
  export LOGNAME="$USER"
fi
if [ -z "${HOME:-}" ]; then
  export HOME="$(eval echo "~${USER}")"
fi

export WINEARCH="${WINEARCH:-win64}"
export WINEPREFIX="${WINEPREFIX:-${NT_DIR}/.wine}"

WINE_BIN="$(command -v wine 2>/dev/null || command -v wine64 2>/dev/null || true)"
if [ -z "$WINE_BIN" ]; then
  echo "wine is not installed. Install wine, wine64, and the needed 32-bit support, then retry."
  exit 1
fi

mkdir -p "$WINEPREFIX"

have_display() {
  if command -v xdpyinfo >/dev/null 2>&1; then
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
    return $?
  fi
  [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]
}

run_wine_cmd() {
  if have_display; then
    "$WINE_BIN" "$@"
    return $?
  fi

  if command -v xvfb-run >/dev/null 2>&1; then
    xvfb-run -a "$WINE_BIN" "$@"
    return $?
  fi

  echo "No X display is available for DISPLAY=${DISPLAY}."
  echo "Start VNC/X first, or install xvfb for headless initialization."
  return 1
}

ensure_wine_prereqs() {
  if [ -n "${WINE_PREREQS_DONE:-}" ]; then
    return 0
  fi

  if [ ! -x "$(command -v winetricks 2>/dev/null || true)" ]; then
    echo "[prereq] winetricks not found; skipping .NET bootstrap" >&2
    WINE_PREREQS_DONE=1
    return 0
  fi

  if [ -f "$WINEPREFIX/.dotnet48.installed" ]; then
    echo "[prereq] .NET 4.8 marker already present" >&2
    WINE_PREREQS_DONE=1
    return 0
  fi

  echo "[prereq] Installing .NET Framework 4.8 into Wine prefix" >&2
  run_wine_cmd winetricks -q dotnet48 >/tmp/ninjatrader-winetricks.log 2>&1 || {
    cat /tmp/ninjatrader-winetricks.log
    echo "[prereq] .NET 4.8 bootstrap failed" >&2
    return 1
  }

  touch "$WINEPREFIX/.dotnet48.installed"
  echo "[prereq] .NET 4.8 installation complete" >&2
  WINE_PREREQS_DONE=1
}

launch_installer_file() {
  local installer_file="$1"
  shift || true
  local wine_path

  wine_path="$(to_wine_path "$installer_file")"
  echo "[launcher] Wine path: $wine_path" >&2

  if is_msi_payload "$installer_file"; then
    echo "[launcher] Detected MSI payload; ensuring .NET prereqs before msiexec" >&2
    ensure_wine_prereqs
    echo "[launcher] Detected MSI payload; using msiexec" >&2
    exec "$WINE_BIN" msiexec /i "$wine_path" "$@"
  fi

  echo "[launcher] Launching directly with Wine" >&2
  exec "$WINE_BIN" "$wine_path" "$@"
}

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  run_wine_cmd wineboot -u >/tmp/ninjatrader-wineboot.log 2>&1 || {
    cat /tmp/ninjatrader-wineboot.log
    if grep -qi 'could not load kernel32\.dll' /tmp/ninjatrader-wineboot.log; then
      echo ""
      echo "Detected broken/incomplete Wine runtime (kernel32.dll missing)."
      echo "On Ubuntu, install 32-bit Wine support and recreate the prefix:"
      echo "  sudo dpkg --add-architecture i386"
      echo "  sudo apt update"
      echo "  sudo apt install -y --install-recommends wine wine64 wine32 winetricks libwine libwine:i386"
      echo "  rm -rf \"${WINEPREFIX}\""
      echo "Then rerun this launcher as your normal deploy user (not root)."
    fi
    if grep -qi 'nodrv_CreateWindow\|Make sure that your X server is running' /tmp/ninjatrader-wineboot.log; then
      echo ""
      echo "Detected missing X display for Wine GUI initialization."
      echo "Start TigerVNC and confirm DISPLAY is reachable:"
      echo "  sudo systemctl restart tigervnc"
      echo "  sudo systemctl status tigervnc --no-pager"
      echo "  export DISPLAY=:1"
      echo "  xdpyinfo -display :1 | head"
      echo "Then rerun this launcher as your deploy user."
    fi
    echo "Wine prefix initialization failed. Check that wine and its dependencies are installed."
    exit 1
  }
fi

NT_EXE="${NT_DIR}/NinjaTrader 8/bin/NinjaTrader.exe"
NT_INSTALLER_MSI="${NT_DIR}/NinjaTraderInstaller.msi"
NT_INSTALLER_EXE="${NT_DIR}/NinjaTraderInstaller.exe"

is_valid_installer_file() {
  local f="$1"
  echo "[installer-check] Testing: $f" >&2
  [ -f "$f" ] || { echo "[installer-check] Not a file" >&2; return 1; }

  case "$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')" in
    *.msi|*.exe) echo "[installer-check] Valid extension" >&2 ;;
    *) echo "[installer-check] Invalid extension" >&2; return 1 ;;
  esac

  if command -v file >/dev/null 2>&1; then
    local ftype
    ftype="$(file "$f" 2>&1)"
    echo "[installer-check] Type: $ftype" >&2
    if echo "$ftype" | grep -Eiq 'html|xml|text|empty'; then
      echo "[installer-check] File type rejected: $ftype" >&2
      return 1
    fi
  fi

  echo "[installer-check] VALID" >&2
  return 0
}

discover_installer_file() {
  echo "[discover] Looking in: $NT_DIR" >&2
  local found
  found="$(find "$NT_DIR" -maxdepth 2 -type f \( -iname '*.msi' -o -iname '*.exe' \) 2>/dev/null | head -n 1 || true)"
  if [ -n "$found" ]; then
    echo "[discover] Found candidate: $found" >&2
    if is_valid_installer_file "$found"; then
      echo "[discover] SUCCESS: $found" >&2
      printf '%s\n' "$found"
      return 0
    fi
  fi
  echo "[discover] No valid installer found" >&2
  return 1
}

download_direct_installer() {
  echo "[download] NT_INSTALLER_URL=$NT_INSTALLER_URL" >&2
  if ! echo "$NT_INSTALLER_URL" | grep -Eiq '\.(msi|exe)(\?.*)?$'; then
    echo "[download] URL does not end with .msi or .exe, skipping" >&2
    return 1
  fi

  local installer_ext installer_file tmp_file
  installer_ext="$(echo "$NT_INSTALLER_URL" | grep -Eoi '\.(msi|exe)' | tr -d '.' | tr '[:upper:]' '[:lower:]')"
  installer_file="${NT_DIR}/NinjaTraderInstaller.${installer_ext}"
  tmp_file="${installer_file}.download"

  echo "[download] Downloading to: $tmp_file" >&2
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$NT_INSTALLER_URL" -o "$tmp_file" 2>&1 | sed 's/^/[curl] /' >&2
  else
    wget -O "$tmp_file" "$NT_INSTALLER_URL" 2>&1 | sed 's/^/[wget] /' >&2
  fi

  if ! is_valid_installer_file "$tmp_file"; then
    echo "[download] Downloaded file failed validation, deleting" >&2
    rm -f "$tmp_file"
    return 1
  fi

  echo "[download] Moving to: $installer_file" >&2
  mv -f "$tmp_file" "$installer_file"
  printf '%s\n' "$installer_file"
  echo "[download] SUCCESS" >&2
  return 0
}

to_wine_path() {
  printf 'Z:%s\n' "$(printf '%s' "$1" | sed 's|/|\\\\|g')"
}

log_file_type() {
  if command -v file >/dev/null 2>&1; then
    echo "[launcher] file: $(file "$1" 2>&1)" >&2
  fi
}

is_msi_payload() {
  if command -v file >/dev/null 2>&1; then
    file "$1" 2>/dev/null | grep -Eiq 'MSI Installer|Installation Database'
  else
    return 1
  fi
}

if [ -f "$NT_EXE" ]; then
  if ! have_display; then
    echo "NinjaTrader requires a GUI display, but DISPLAY=${DISPLAY} is not available."
    echo "Start VNC first: sudo systemctl restart tigervnc"
    exit 1
  fi
  exec "$WINE_BIN" "$NT_EXE" "$@"
fi

if [ -f "$NT_INSTALLER_MSI" ] && is_valid_installer_file "$NT_INSTALLER_MSI"; then
  echo "[launcher] Using existing: $NT_INSTALLER_MSI" >&2
  log_file_type "$NT_INSTALLER_MSI"
  if ! have_display; then
    echo "NinjaTrader installer requires a GUI display, but DISPLAY=${DISPLAY} is not available."
    echo "Start VNC first: sudo systemctl restart tigervnc"
    exit 1
  fi
  launch_installer_file "$NT_INSTALLER_MSI" "$@"
fi

if [ -f "$NT_INSTALLER_EXE" ] && is_valid_installer_file "$NT_INSTALLER_EXE"; then
  echo "[launcher] Using existing: $NT_INSTALLER_EXE" >&2
  log_file_type "$NT_INSTALLER_EXE"
  if ! have_display; then
    echo "NinjaTrader installer requires a GUI display, but DISPLAY=${DISPLAY} is not available."
    echo "Start VNC first: sudo systemctl restart tigervnc"
    exit 1
  fi
  launch_installer_file "$NT_INSTALLER_EXE" "$@"
fi

echo "[launcher] No pre-existing installer found. Attempting runtime discovery/download..." >&2

if installer_path="$(download_direct_installer 2>&1)"; then
  echo "[launcher] Downloaded installer: $installer_path" >&2
  log_file_type "$installer_path"
  if ! have_display; then
    echo "Installer was downloaded but DISPLAY=${DISPLAY} is not available."
    echo "Start VNC first: sudo systemctl restart tigervnc"
    exit 1
  fi
  launch_installer_file "$installer_path" "$@"
fi

if installer_path="$(discover_installer_file 2>&1)"; then
  echo "[launcher] Discovered installer: $installer_path" >&2
  log_file_type "$installer_path"
  if ! have_display; then
    echo "NinjaTrader installer requires a GUI display, but DISPLAY=${DISPLAY} is not available."
    echo "Start VNC first: sudo systemctl restart tigervnc"
    exit 1
  fi
  launch_installer_file "$installer_path" "$@"
fi

echo ""
echo "========== INSTALLER NOT FOUND =========="
echo "NinjaTrader installer or executable was not found and could not be downloaded."
echo ""
echo "To fix this, you have two options:"
echo ""
echo "Option 1: Set NT_INSTALLER_URL to a direct download link (.msi or .exe)"
echo "  Edit /opt/ninja-trader-executor/.env and set:"
echo "  NT_INSTALLER_URL=https://example.com/NinjaTraderInstaller.msi"
echo "  Then rerun: bash /opt/ninja-trader-executor/deploy_ubuntu.sh"
echo ""
echo "Option 2: Place installer manually into /opt/ninjatrader"
echo "  cp /path/to/NinjaTraderInstaller.msi /opt/ninjatrader/"
echo "  Then rerun: bash /opt/ninja-trader-executor/deploy_ubuntu.sh"
echo ""
echo "Current NT_INSTALLER_URL: ${NT_INSTALLER_URL}"
echo "NT_DIR: ${NT_DIR}"
echo "=========================================="
sleep 10
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

if [ "$AUTO_LAUNCH_NINJATRADER" = "1" ]; then
  echo "Waiting for X display ${VNC_DISPLAY} to become ready..."
  for _ in $(seq 1 45); do
    if sudo -u "$DEPLOY_USER" env DISPLAY="$VNC_DISPLAY" xdpyinfo >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if sudo -u "$DEPLOY_USER" env DISPLAY="$VNC_DISPLAY" xdpyinfo >/dev/null 2>&1; then
    # Avoid duplicate launcher processes when rerunning deployment.
    sudo -u "$DEPLOY_USER" pkill -f "$NT_LAUNCHER_WRAPPER" >/dev/null 2>&1 || true

    sudo -u "$DEPLOY_USER" env \
      DISPLAY="$VNC_DISPLAY" \
      HOME="$DEPLOY_HOME" \
      USER="$DEPLOY_USER" \
      LOGNAME="$DEPLOY_USER" \
      NT_DIR="$NT_DIR" \
      NT_INSTALLER_URL="$NT_INSTALLER_URL" \
      WINEPREFIX="${NT_DIR}/.wine" \
      nohup "$NT_LAUNCHER_WRAPPER" >/tmp/ninjatrader-launch.log 2>&1 &

    echo "NinjaTrader launcher started automatically."
    echo "Launcher log: /tmp/ninjatrader-launch.log"
  else
    echo "Could not auto-launch NinjaTrader because DISPLAY ${VNC_DISPLAY} is not ready."
    echo "Run manually after VNC is up:"
    echo "  sudo -u ${DEPLOY_USER} env DISPLAY=${VNC_DISPLAY} HOME=${DEPLOY_HOME} ${NT_LAUNCHER_WRAPPER}"
  fi
fi

echo "NinjaTrader installer file is available in: ${NT_DIR}"
echo "Installer auto-launch is enabled by default (AUTO_LAUNCH_NINJATRADER=1)."

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
