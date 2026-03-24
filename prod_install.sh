#!/bin/bash

# ==========================================
#  TACTICAL DVR - FIELD INSTALLATION SCRIPT
#  Version: 1.6.5 (Field Ready)
# ==========================================

# --- הגדרות משתמש ---
PROJECT_DIR="$HOME/TacticalDVR"
USER_NAME=$(whoami)

# Handle GitHub Token (Optional for public dvr-updates repo)
if [ -z "$GITHUB_TOKEN" ]; then
    echo "💡 Note: GitHub Token is optional for public releases from 'dvr-updates'."
    echo -n "   Enter GitHub Token if you need to access private assets (or press Enter to skip): "
    read -s GITHUB_TOKEN
    echo ""
fi

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
    if [ -n "$SUDO_PASSWORD" ]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@"
    else
        sudo "$@"
    fi
}

# הגדרות GitHub Release (Using public updates repo)
REPO_USER="YuvalHir"
REPO_NAME="dvr-updates"

# Helper for curl with optional token
github_curl() {
    if [ -n "$GITHUB_TOKEN" ]; then
        curl -H "Authorization: token $GITHUB_TOKEN" "$@"
    else
        curl "$@"
    fi
}

# Automatically find the latest tag if not specified
if [ -z "$TAG" ]; then
    echo "🔍 Checking GitHub for the latest version..."
    TAG=$(github_curl -s "https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
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
run_sudo apt install -y x11-xserver-utils wget curl gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav ffmpeg unclutter v4l-utils gvfs-backends gvfs-fuse mtp-tools libmtp-runtime libimobiledevice6 ifuse

# 2. יצירת מבנה תיקיות
echo "[2/9] Creating directories..."
mkdir -p "$PROJECT_DIR/dist"
mkdir -p "$PROJECT_DIR/logs"
mkdir -p "$PROJECT_DIR/assets"

# 3. Preparing Logo
echo "[3/9] Preparing Logo..."
# Logo is in public repo, no token needed
LOGO_URL="https://github.com/YuvalHir/dvr-updates/raw/main/$SELECTED_LOGO"
curl -L -o "$PROJECT_DIR/assets/tactical_logo.png" "$LOGO_URL"
cp "$PROJECT_DIR/assets/tactical_logo.png" "$PROJECT_DIR/dist/tactical_logo.png"

# 4. הכנת קבצים בינאריים (SHA-256 Verification)
echo "[4/9] Preparing binaries..."

is_online() {
    curl -s --connect-timeout 2 https://google.com > /dev/null
    return $?
}

verify_sha() {
    local filename=$1
    local local_file=$2
    local remote_sha_url=$3
    
    if [ ! -f "$local_file" ]; then return 1; fi
    
    echo "      Verifying $filename checksum..."
    local remote_sha=$(github_curl -s -L "$remote_sha_url" | tr -d '[:space:]')
    local local_sha=$(sha256sum "$local_file" | awk '{print $1}' | tr -d '[:space:]')
    
    if [ "$remote_sha" == "$local_sha" ]; then
        return 0 # Match
    else
        return 1 # Mismatch
    fi
}

RELEASE_INFO=$(github_curl -s "https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/tags/$TAG")

get_asset_url() {
    # Switch to browser_download_url for public access without token
    echo "$RELEASE_INFO" | grep -C 5 "\"name\": \"$1\"" | grep "\"browser_download_url\":" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/'
}

RECORDER_URL=$(get_asset_url "tactical_recorder")
PLAYER_URL=$(get_asset_url "tactical_player")
RECORDER_SHA_URL=$(get_asset_url "tactical_recorder.sha256")
PLAYER_SHA_URL=$(get_asset_url "tactical_player.sha256")

NEED_RECORDER=true
NEED_PLAYER=true

if is_online; then
    echo "🌐 System is online. Checking for updates..."
    
    # Check current dir (SCP destination) first
    if [ -f "./tactical_recorder" ]; then
        if verify_sha "tactical_recorder" "./tactical_recorder" "$RECORDER_SHA_URL"; then
            echo "   -> Local tactical_recorder is up to date."
            cp "./tactical_recorder" "$PROJECT_DIR/dist/tactical_recorder"
            NEED_RECORDER=false
        fi
    fi
    
    # Check already installed dist if not found in current dir
    if [ "$NEED_RECORDER" = true ] && [ -f "$PROJECT_DIR/dist/tactical_recorder" ]; then
        if verify_sha "tactical_recorder" "$PROJECT_DIR/dist/tactical_recorder" "$RECORDER_SHA_URL"; then
            echo "   -> Installed tactical_recorder is up to date."
            NEED_RECORDER=false
        fi
    fi

    # Same for Player
    if [ -f "./tactical_player" ]; then
        if verify_sha "tactical_player" "./tactical_player" "$PLAYER_SHA_URL"; then
            echo "   -> Local tactical_player is up to date."
            cp "./tactical_player" "$PROJECT_DIR/dist/tactical_player"
            NEED_PLAYER=false
        fi
    fi
    if [ "$NEED_PLAYER" = true ] && [ -f "$PROJECT_DIR/dist/tactical_player" ]; then
        if verify_sha "tactical_player" "$PROJECT_DIR/dist/tactical_player" "$PLAYER_SHA_URL"; then
            echo "   -> Installed tactical_player is up to date."
            NEED_PLAYER=false
        fi
    fi
else
    echo "📡 System is offline. Using local files..."
    # If scp'd to current dir, use them
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
    echo "   -> Downloading latest tactical_recorder..."
    # No Authorization or Accept headers needed for browser_download_url
    curl -L -o "$PROJECT_DIR/dist/tactical_recorder" "$RECORDER_URL"
fi
if [ "$NEED_PLAYER" = true ]; then
    echo "   -> Downloading latest tactical_player..."
    curl -L -o "$PROJECT_DIR/dist/tactical_player" "$PLAYER_URL"
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
# Critical for compatibility with military devices
xrandr --output HDMI-1 --set "max bpc" 8 2>/dev/null
xrandr --output HDMI-1 --set "Broadcast RGB" "Limited 16-235" 2>/dev/null
xrandr --output HDMI-1 --mode 1920x1080 --rate 60 2>/dev/null

# --- Power Management Disable ---
pkill -f xscreensaver 2>/dev/null
xset s off
xset -dpms
xset s noblank 2>/dev/null
xhost +local:\$(whoami) > /dev/null

# XFCE specific tweaks
if command -v xfconf-query >/dev/null 2>&1; then
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null
    xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null
fi

# --- Hide Mouse Cursor ---
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

    # --- תיקון קריטי לרוחב פס USB (עבור Dual Capture Card) ---
    echo "[Extra] Applying USB Bandwidth Fix (Quirks)..."
    echo "options uvcvideo quirks=128" | run_sudo tee /etc/modprobe.d/uvcvideo.conf > /dev/null
    # ניסיון טעינה מיידי
    run_sudo modprobe -r uvcvideo 2>/dev/null || true
    run_sudo modprobe uvcvideo quirks=128 2>/dev/null || true
fi

# --- Hardware Acceleration Setup ---
echo "[Hardware Acceleration] Checking for Intel iGPU..."
if lspci | grep -i "vga.*intel" > /dev/null; then
    echo "   -> Intel iGPU detected. Installing VA-API drivers..."
    run_sudo apt install -y intel-media-va-driver-non-free vainfo gstreamer1.0-vaapi

    echo "   -> Validating Hardware Acceleration..."
    # Check if vainfo reports H264 decoding profile (VLD)
    if vainfo 2>&1 | grep -i "VAProfileH264.*VAEntrypointVLD" > /dev/null; then
        echo "============================================="
        echo "   ✅ Hardware Acceleration: Supported and Active"
        echo "============================================="
    else
        echo "============================================="
        echo "   ⚠️ Hardware Acceleration: Drivers installed, but validation failed."
        echo "      Falling back to Software Decoding."
        echo "============================================="
    fi
else
    echo "============================================="
    echo "   ➖ Hardware Acceleration: Not Supported/Failed (No Intel iGPU found)."
    echo "      Using Software Decoding."
    echo "============================================="
fi

echo "============================================="
echo "   ✅ INSTALLATION COMPLETE!"
echo "============================================="
