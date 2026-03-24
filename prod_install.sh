#!/bin/bash

# ==========================================
#  TACTICAL DVR - FIELD INSTALLATION SCRIPT
#  Version: 1.6.5 (Zero-Auth Ready)
# ==========================================

# Exit on error, but handle some errors manually
set -e

# --- הגדרות משתמש ---
PROJECT_DIR="$HOME/TacticalDVR"
USER_NAME=$(whoami)

# --- Logo Selection ---
echo "🎨 Choose Tactical Logo:"
echo "1) Meyuhadim (Default)"
echo "2) Dromit"
echo "3) Zfonit"
echo -n "Select option [1-3]: "
read LOGO_CHOICE

case $LOGO_CHOICE in
    2) SELECTED_LOGO="tactical_logo_dromit.png" ;;
    3) SELECTED_LOGO="tactical_logo_zfonit.png" ;;
    *) SELECTED_LOGO="tactical_logo.png" ;;
esac

# --- Helper for sudo ---
run_sudo() {
    if [ -n "${SUDO_PASSWORD:-}" ]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@"
    else
        sudo "$@"
    fi
}

# הגדרות GitHub Release (Using public updates repo)
REPO_USER="YuvalHir"
REPO_NAME="dvr-updates"

# Helper for curl with optional token and validation
github_curl() {
    local url="$1"
    if [ -z "$url" ]; then
        return 0
    fi
    
    # Use array for curl arguments to prevent 'blank argument' issues
    local curl_opts=(-s -L)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
    fi
    
    curl "${curl_opts[@]}" "$url"
}

# Automatically find the latest tag if not specified
if [ -z "${TAG:-}" ]; then
    echo "🔍 Checking GitHub for the latest version..."
    LATEST_JSON=$(github_curl "https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/latest" || echo "{}")
    TAG=$(echo "$LATEST_JSON" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    
    if [ -z "$TAG" ]; then
        echo "⚠️  Could not detect latest tag, falling back to V1.6.5"
        TAG="V1.6.5"
    fi
fi
echo "🚀 Target Version: $TAG"

# --- 0. Pre-Cleanup ---
if [ -f "$PROJECT_DIR/watchdog.sh" ]; then
    IS_UPDATE=true
    echo "--- UPDATER MODE ---"
    echo "[0/9] Stopping running processes..."
    systemctl --user stop tactical-dvr.service 2>/dev/null || true
    pkill -9 -f watchdog.sh 2>/dev/null || true
    pkill -9 -f tactical_recorder 2>/dev/null || true
    pkill -9 -f tactical_player 2>/dev/null || true
    sleep 1
else
    IS_UPDATE=false
    echo "--- INSTALLER MODE ---"
fi

# 1. התקנת תלויות מערכת
echo "[1/9] Installing system dependencies..."
run_sudo apt update

# Function to check if a package is truly available for installation
is_pkg_available() {
    # Check if package exists AND has an installation candidate
    apt-cache policy "$1" 2>/dev/null | grep -q "Candidate: [^ ]" && \
    ! apt-cache policy "$1" 2>/dev/null | grep -q "Candidate: (none)"
}

# Base packages that usually have stable names
PKGS="x11-xserver-utils wget curl gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav ffmpeg unclutter v4l-utils gvfs-backends gvfs-fuse mtp-tools libmtp-runtime ifuse"

# Add libimobiledevice based on availability (Prefer the newer name for Trixie)
if is_pkg_available "libimobiledevice-1.0-6"; then
    PKGS="$PKGS libimobiledevice-1.0-6"
elif is_pkg_available "libimobiledevice6"; then
    PKGS="$PKGS libimobiledevice6"
else
    echo "⚠️  Warning: Neither libimobiledevice-1.0-6 nor libimobiledevice6 found."
fi

# Add gstreamer-ugly if available (sometimes omitted in certain distros)
if is_pkg_available "gstreamer1.0-plugins-ugly"; then
    PKGS="$PKGS gstreamer1.0-plugins-ugly"
fi

echo "   -> Installing: $PKGS"
run_sudo apt install -y $PKGS

# 2. יצירת מבנה תיקיות
echo "[2/9] Creating directories..."
mkdir -p "$PROJECT_DIR/dist"
mkdir -p "$PROJECT_DIR/logs"
mkdir -p "$PROJECT_DIR/assets"

# 3. Preparing Logo
echo "[3/9] Preparing Logo..."
LOGO_URL="https://github.com/YuvalHir/dvr-updates/raw/main/$SELECTED_LOGO"
if curl -s -L --head "$LOGO_URL" | grep "200 OK" > /dev/null; then
    curl -L -o "$PROJECT_DIR/assets/tactical_logo.png" "$LOGO_URL"
    cp "$PROJECT_DIR/assets/tactical_logo.png" "$PROJECT_DIR/dist/tactical_logo.png"
else
    echo "⚠️  Could not find logo at $LOGO_URL, using default placeholder."
fi

# 4. הכנת קבצים בינאריים (SHA-256 Verification)
echo "[4/9] Preparing binaries..."

is_online() {
    curl -s --connect-timeout 2 https://google.com > /dev/null && return 0 || return 1
}

verify_sha() {
    local filename=$1
    local local_file=$2
    local remote_sha_url=$3
    
    if [ ! -f "$local_file" ] || [ -z "$remote_sha_url" ]; then 
        return 1
    fi
    
    echo "      Verifying $filename checksum..."
    local remote_sha=$(github_curl "$remote_sha_url" | tr -d '[:space:]')
    local local_sha=$(sha256sum "$local_file" | awk '{print $1}' | tr -d '[:space:]')
    
    if [ -n "$remote_sha" ] && [ "$remote_sha" == "$local_sha" ]; then
        return 0
    else
        return 1
    fi
}

RELEASE_JSON=$(github_curl "https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/tags/$TAG" || echo "{}")

get_asset_url() {
    local asset_name="$1"
    echo "$RELEASE_JSON" | grep -C 5 "\"name\": \"$asset_name\"" | grep "\"browser_download_url\":" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true
}

RECORDER_URL=$(get_asset_url "tactical_recorder")
PLAYER_URL=$(get_asset_url "tactical_player")
RECORDER_SHA_URL=$(get_asset_url "tactical_recorder.sha256")
PLAYER_SHA_URL=$(get_asset_url "tactical_player.sha256")

NEED_RECORDER=true
NEED_PLAYER=true

if is_online; then
    echo "🌐 System is online. Checking for updates..."
    
    if [ -f "./tactical_recorder" ] && [ -n "$RECORDER_SHA_URL" ]; then
        if verify_sha "tactical_recorder" "./tactical_recorder" "$RECORDER_SHA_URL"; then
            echo "   -> Local tactical_recorder is up to date."
            cp "./tactical_recorder" "$PROJECT_DIR/dist/tactical_recorder"
            NEED_RECORDER=false
        fi
    fi
    
    if [ "$NEED_RECORDER" = true ] && [ -f "$PROJECT_DIR/dist/tactical_recorder" ] && [ -n "$RECORDER_SHA_URL" ]; then
        if verify_sha "tactical_recorder" "$PROJECT_DIR/dist/tactical_recorder" "$RECORDER_SHA_URL"; then
            echo "   -> Installed tactical_recorder is up to date."
            NEED_RECORDER=false
        fi
    fi

    if [ -f "./tactical_player" ] && [ -n "$PLAYER_SHA_URL" ]; then
        if verify_sha "tactical_player" "./tactical_player" "$PLAYER_SHA_URL"; then
            echo "   -> Local tactical_player is up to date."
            cp "./tactical_player" "$PROJECT_DIR/dist/tactical_player"
            NEED_PLAYER=false
        fi
    fi
    if [ "$NEED_PLAYER" = true ] && [ -f "$PROJECT_DIR/dist/tactical_player" ] && [ -n "$PLAYER_SHA_URL" ]; then
        if verify_sha "tactical_player" "$PROJECT_DIR/dist/tactical_player" "$PLAYER_SHA_URL"; then
            echo "   -> Installed tactical_player is up to date."
            NEED_PLAYER=false
        fi
    fi
else
    echo "📡 System is offline. Using local files..."
    if [ -f "./tactical_recorder" ]; then cp "./tactical_recorder" "$PROJECT_DIR/dist/tactical_recorder"; fi
    if [ -f "./tactical_player" ]; then cp "./tactical_player" "$PROJECT_DIR/dist/tactical_player"; fi
    
    if [ -f "$PROJECT_DIR/dist/tactical_recorder" ] && [ -f "$PROJECT_DIR/dist/tactical_player" ]; then
        echo "   -> Using existing binaries."
        NEED_RECORDER=false
        NEED_PLAYER=false
    else
        echo "❌ ERROR: System offline and binaries missing."
        exit 1
    fi
fi

# Download if still needed
if [ "$NEED_RECORDER" = true ]; then
    if [ -n "$RECORDER_URL" ]; then
        echo "   -> Downloading latest tactical_recorder..."
        curl -L -o "$PROJECT_DIR/dist/tactical_recorder" "$RECORDER_URL"
    else
        echo "❌ ERROR: Could not find tactical_recorder in release $TAG"
        exit 1
    fi
fi
if [ "$NEED_PLAYER" = true ]; then
    if [ -n "$PLAYER_URL" ]; then
        echo "   -> Downloading latest tactical_player..."
        curl -L -o "$PROJECT_DIR/dist/tactical_player" "$PLAYER_URL"
    else
        echo "❌ ERROR: Could not find tactical_player in release $TAG"
        exit 1
    fi
fi

# 5. הגדרת הרשאות
echo "[5/9] Setting permissions..."
chmod +x "$PROJECT_DIR/dist/tactical_recorder"
chmod +x "$PROJECT_DIR/dist/tactical_player"
run_sudo chown -R $USER_NAME:$USER_NAME "$PROJECT_DIR"

if [ "$IS_UPDATE" = true ]; then
    echo "[Update] Restarting services..."
    "$PROJECT_DIR/watchdog.sh" &
else
    # 6. הגדרת כניסה אוטומטית
    echo "[6/9] Configuring Auto-login..."
    run_sudo groupadd -r autologin 2>/dev/null || true
    run_sudo gpasswd -a $USER_NAME autologin
    run_sudo gpasswd -a $USER_NAME video
    run_sudo sed -i "s/^#\?autologin-user=.*/autologin-user=$USER_NAME/" /etc/lightdm/lightdm.conf
    run_sudo sed -i "s/^#\?autologin-user-timeout=.*/autologin-user-timeout=0/" /etc/lightdm/lightdm.conf

    # 7. יצירת סקריפט ה-Watchdog
    echo "[7/9] Creating Watchdog script..."
    cat <<EOF > "$PROJECT_DIR/watchdog.sh"
#!/bin/bash
export DISPLAY=:0
export XAUTHORITY=\$HOME/.Xauthority

# --- SHADLAN FIX (8-bit + Limited RGB + Force 1080p) ---
xrandr --output HDMI-1 --set "max bpc" 8 2>/dev/null
xrandr --output HDMI-1 --set "Broadcast RGB" "Limited 16-235" 2>/dev/null
xrandr --output HDMI-1 --mode 1920x1080 --rate 60 2>/dev/null

pkill -f xscreensaver 2>/dev/null
xset s off
xset -dpms
xset s noblank 2>/dev/null
xhost +local:\$(whoami) > /dev/null

if command -v xfconf-query >/dev/null 2>&1; then
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null
    xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null
fi

unclutter -idle 0.1 -root & 

LOG_DIR="$PROJECT_DIR/logs"
manage_app() {
    local app_name=\$1
    local app_path=\$2
    local binary_name=\$(basename "\$app_path")
    while true; do
        if ! pgrep -f "\$binary_name" > /dev/null; then
            echo "\$(date): \$app_name is down. Launching..." >> "\$LOG_DIR/\${app_name}.log"
            pkill -9 -f "\$binary_name" 2>/dev/null
            sleep 1
            "\$app_path" >> "\$LOG_DIR/\${app_name}.log" 2>&1 &
        fi
        sleep 3
    done
}
mkdir -p "\$LOG_DIR"
cd "$PROJECT_DIR" || exit 1
manage_app "recorder" "$PROJECT_DIR/dist/tactical_recorder" &
sleep 2
manage_app "player" "$PROJECT_DIR/dist/tactical_player" &
wait
EOF
    chmod +x "$PROJECT_DIR/watchdog.sh"

    # 8. הגדרת Autostart
    echo "[8/9] Setting up Autostart..."
    mkdir -p ~/.config/autostart
    cat <<EOF > ~/.config/autostart/tactical-dvr.desktop
[Desktop Entry]
Type=Application
Exec=$PROJECT_DIR/watchdog.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Tactical DVR
EOF

    # 9. הגדרת GRUB
    echo "[9/9] Configuring system..."
    run_sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash net.ifnames=0 biosdevname=0"/' /etc/default/grub
    run_sudo update-grub 2>/dev/null || true

    echo "[Extra] Applying USB Bandwidth Fix (Quirks)..."
    echo "options uvcvideo quirks=128" | run_sudo tee /etc/modprobe.d/uvcvideo.conf > /dev/null
    run_sudo modprobe -r uvcvideo 2>/dev/null || true
    run_sudo modprobe uvcvideo quirks=128 2>/dev/null || true
fi

echo "[Hardware Acceleration] Checking for Intel iGPU..."
if lspci | grep -i "vga.*intel" > /dev/null; then
    run_sudo apt install -y intel-media-va-driver-non-free vainfo gstreamer1.0-vaapi
    if vainfo 2>&1 | grep -i "VAProfileH264.*VAEntrypointVLD" > /dev/null; then
        echo "   ✅ Hardware Acceleration Active"
    fi
fi

echo "============================================="
echo "   ✅ INSTALLATION COMPLETE!"
echo "============================================="
