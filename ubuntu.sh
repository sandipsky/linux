#!/usr/bin/env bash
# Post-install setup for a fresh Ubuntu (GNOME) install.
# Run from a clone of the repo (it needs fonts/ and icons/): sudo ./ubuntu.sh
set -eE

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "Run this script with bash, not sh: sudo ./ubuntu.sh"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo: sudo ./ubuntu.sh"
    exit 1
fi
# The prompts are read from the terminal, so `curl ... | sudo bash` can't work.
if [[ ! -t 1 ]] || ! { : </dev/tty; } 2>/dev/null; then
    echo "This script needs an interactive terminal (it asks questions). Clone the repo and run: sudo ./ubuntu.sh"
    exit 1
fi

USERNAME=$(logname)
USER_UID=$(id -u "$USERNAME")
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

if [[ ! -d "$REPO_DIR/fonts/fira" || ! -d "$REPO_DIR/icons" ]]; then
    echo "fonts/ and icons/ not found next to the script ($REPO_DIR). Run it from a full clone of the repo."
    exit 1
fi

# Everything the script prints also goes to a log, so a failed run can be diagnosed.
LOG=/var/log/ubuntu-postinstall.log
exec > >(tee -a "$LOG") 2>&1
echo "=== ubuntu.sh started $(date -Is) (log: $LOG)"

# With `set -e` a failing command silently ends the script; say where it died.
trap 'echo; echo "ERROR: ubuntu.sh stopped at line $LINENO: $BASH_COMMAND (see $LOG)" >&2' ERR

. /etc/os-release
CODENAME="${VERSION_CODENAME}"

VIRT=$(systemd-detect-virt 2>/dev/null) || VIRT=none

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
# ask_yesno VAR "question": sets VAR to yes or no (Enter = yes). Reads the
# terminal directly so the answer can't be swallowed by a pipe or redirect.
ask_yesno() {
    local var=$1 question=$2 answer
    while true; do
        read -rp "$question [Y/n]: " answer </dev/tty
        case "${answer,,}" in
            ''|y|yes) printf -v "$var" '%s' yes; return 0 ;;
            n|no)     printf -v "$var" '%s' no;  return 0 ;;
            *)        echo "Please answer y or n." ;;
        esac
    done
}

# as_user CMD...: run a command as the login user with a D-Bus session, so
# gsettings/gnome-extensions write to that user's dconf. Uses the user's live
# session bus when one exists (changes apply immediately), otherwise a
# throwaway bus (changes apply at next login).
USER_BUS="/run/user/$USER_UID/bus"
as_user() {
    if [[ -S "$USER_BUS" ]]; then
        sudo -u "$USERNAME" -H env XDG_RUNTIME_DIR="/run/user/$USER_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS" "$@"
    else
        sudo -u "$USERNAME" -H dbus-run-session -- "$@"
    fi
}

# user_gsettings SCHEMA KEY VALUE: set a gsettings key for the login user and
# report it, so a write that didn't land is visible in the log.
user_gsettings() {
    if as_user gsettings set "$1" "$2" "$3"; then
        echo "gsettings: $1 $2 = $(as_user gsettings get "$1" "$2" 2>/dev/null || echo '?')"
    else
        echo "WARNING: could not set $1 $2 for $USERNAME"
    fi
}

# ============================================================
# PROMPTS
# ============================================================
echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
echo
read -rp "NTFS partition to mount at /mnt/HOME (e.g. /dev/nvme1n1p1, blank to skip): " NTFS_DRIVE </dev/tty
case "${NTFS_DRIVE,,}" in n|no|none|skip) NTFS_DRIVE="" ;; esac
ask_yesno INSTALL_DEV     "Install the development stack (node, JDK, Angular CLI, Docker, Postman)?"
ask_yesno INSTALL_GAMING  "Install the gaming stack (wine, winetricks, lutris)?"
ask_yesno INSTALL_ADWAITA "Replace Ubuntu's Yaru theme with stock GNOME Adwaita (keeps Yaru's orange folder icons)?"

echo
echo "Summary:"
echo "  NTFS drive to mount : ${NTFS_DRIVE:-none}"
echo "  Development stack   : $INSTALL_DEV"
echo "  Gaming stack        : $INSTALL_GAMING"
echo "  Yaru -> Adwaita     : $INSTALL_ADWAITA"
echo "  Logged-in user      : $USERNAME"
echo
ask_yesno CONFIRM "Proceed with these choices?"
if [[ "$CONFIRM" != yes ]]; then
    echo "Aborted — nothing was changed."
    exit 0
fi

# ============================================================
# BASE UPDATE
# ============================================================
apt-get update
apt-get full-upgrade -y

# ============================================================
# REMOVE SNAP
# ============================================================
if command -v snap >/dev/null 2>&1; then
    for _ in 1 2 3 4 5; do
        SNAPS=$(snap list 2>/dev/null | awk 'NR>1 {print $1}') || SNAPS=""
        [[ -z "$SNAPS" ]] && break
        for s in $SNAPS; do
            snap remove --purge "$s" 2>/dev/null || true
        done
    done
    systemctl disable --now snapd.socket snapd.service snapd.seeded.service 2>/dev/null || true
fi
apt-get purge -y snapd gnome-software-plugin-snap 2>/dev/null || apt-get purge -y snapd || true
apt-get autoremove -y --purge
rm -rf /var/cache/snapd /var/snap /snap /root/snap "/home/$USERNAME/snap"

cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

# ============================================================
# THIRD-PARTY APT REPOS (Chrome, VS Code, Docker)
# ============================================================
# git and jq are needed later (spotify-adblock, GNOME extension) even without the dev stack.
apt-get install -y curl wget gpg apt-transport-https ca-certificates git jq
install -d -m 0755 /etc/apt/keyrings

# Google Chrome
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list

# VS Code
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list

# Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y google-chrome-stable code

# ============================================================
# GAMING STACK (optional)
# ============================================================
if [[ "$INSTALL_GAMING" != yes ]]; then
    echo "Skipping the gaming stack (answered '$INSTALL_GAMING')."
else
    dpkg --add-architecture i386

    # WineHQ staging, falling back to Ubuntu's wine if WineHQ has no repo for this codename.
    if wget -q -O "/etc/apt/sources.list.d/winehq-$CODENAME.sources" \
            "https://dl.winehq.org/wine-builds/ubuntu/dists/$CODENAME/winehq-$CODENAME.sources"; then
        wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
        apt-get update
        apt-get install -y --install-recommends winehq-staging
    else
        rm -f "/etc/apt/sources.list.d/winehq-$CODENAME.sources"
        echo "WineHQ has no repo for '$CODENAME' yet — installing Ubuntu's wine instead."
        apt-get update
        apt-get install -y --install-recommends wine
    fi

    apt-get install -y winetricks lutris
fi

# ============================================================
# VIRTUALBOX GUEST ADDITIONS
# ============================================================
if [[ "$VIRT" == "oracle" || "$VIRT" == "virtualbox" ]]; then
    echo "VirtualBox detected — installing guest additions."
    apt-get install -y virtualbox-guest-utils virtualbox-guest-x11 \
        || apt-get install -y virtualbox-guest-utils \
        || echo "Guest additions install failed — clipboard/resolution integration won't work."
    getent group vboxsf >/dev/null && usermod -aG vboxsf "$USERNAME" || true
    systemctl enable virtualbox-guest-utils.service 2>/dev/null || true
fi

# ============================================================
# PROGRAMS
# ============================================================
apt-get install -y \
    vlc \
    obs-studio \
    qbittorrent

# ============================================================
# GNOME SOFTWARE (deb packages only)
# ============================================================
apt-get install -y --no-install-recommends gnome-software packagekit
apt-get purge -y gnome-software-plugin-flatpak gnome-software-plugin-snap 2>/dev/null || true

# ============================================================
# DEVELOPMENT STACK (optional)
# ============================================================
if [[ "$INSTALL_DEV" != yes ]]; then
    echo "Skipping the development stack (answered '$INSTALL_DEV')."
else
    apt-get install -y build-essential pkg-config

    # Node.js LTS via NodeSource
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs

    # JDK (newest available)
    apt-get install -y openjdk-25-jdk 2>/dev/null \
        || apt-get install -y openjdk-21-jdk 2>/dev/null \
        || apt-get install -y default-jdk

    # Angular CLI
    sudo -u "$USERNAME" -H npm install -g @angular/cli --prefix="/home/$USERNAME/.local"

    # Docker
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$USERNAME"

    # Postman (official tarball into /opt)
    POSTMAN_TAR=$(mktemp)
    curl -fsSL https://dl.pstmn.io/download/latest/linux_64 -o "$POSTMAN_TAR"
    rm -rf /opt/Postman
    tar -xzf "$POSTMAN_TAR" -C /opt
    rm -f "$POSTMAN_TAR"
    ln -sf /opt/Postman/Postman /usr/local/bin/postman
    cat > /usr/share/applications/postman.desktop <<'EOF'
[Desktop Entry]
Name=Postman
Exec=/opt/Postman/Postman %U
Icon=/opt/Postman/app/resources/app/assets/icon.png
Type=Application
Categories=Development;
Terminal=false
EOF
fi

# ============================================================
# GIT GLOBAL CONFIG (only when not already set)
# ============================================================
sudo -u "$USERNAME" -H git config --global user.name >/dev/null 2>&1 \
    || sudo -u "$USERNAME" -H git config --global user.name "sandipsky"
sudo -u "$USERNAME" -H git config --global user.email >/dev/null 2>&1 \
    || sudo -u "$USERNAME" -H git config --global user.email "sandipshakya75@gmail.com"
sudo -u "$USERNAME" -H git config --global core.pager >/dev/null 2>&1 \
    || sudo -u "$USERNAME" -H git config --global core.pager cat

# ============================================================
# BATTERY CHARGE THRESHOLD (80%)
# ============================================================
# Only on real hardware with a battery that exposes a threshold control.
if [[ "$VIRT" != none ]]; then
    echo "Running in a VM ($VIRT) — skipping the battery charge threshold."
elif ! compgen -G "/sys/class/power_supply/BAT*/charge_control_end_threshold" >/dev/null; then
    echo "No battery with a charge threshold control — skipping the battery charge threshold."
else
    cat > /etc/systemd/system/battery-charge-threshold.service <<'EOF'
[Unit]
Description=Set battery charge threshold
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
StartLimitBurst=0

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'echo 80 | tee /sys/class/power_supply/BAT*/charge_control_end_threshold > /dev/null'

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
    systemctl daemon-reload
    systemctl enable battery-charge-threshold.service
    systemctl start battery-charge-threshold.service || true
fi

# ============================================================
# SILENT + FAST BOOT
# ============================================================
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 i915.fastboot=1 nowatchdog mitigations=off"/' /etc/default/grub
# Stop GRUB showing a 30 s menu after an unclean shutdown.
if grep -q '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub; then
    sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=0/' /etc/default/grub
else
    echo 'GRUB_RECORDFAIL_TIMEOUT=0' >> /etc/default/grub
fi
# Windows is booted via the firmware boot menu, so keep os-prober off.
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
fi
update-grub

# Don't block boot waiting for the network.
systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true

# Plymouth splash on startup only: mask the shutdown/reboot units so
# powering off goes straight to the quiet console.
systemctl mask plymouth-poweroff.service plymouth-reboot.service plymouth-halt.service plymouth-kexec.service 2>/dev/null || true

# ============================================================
# NTFS DRIVE
# ============================================================
if [[ -n "$NTFS_DRIVE" ]]; then
    apt-get install -y ntfs-3g
    NTFS_UUID=$(blkid -s UUID -o value "$NTFS_DRIVE" 2>/dev/null) || NTFS_UUID=""
    if [[ -n "$NTFS_UUID" ]]; then
        mkdir -p /mnt/HOME
        if ! grep -q "UUID=$NTFS_UUID" /etc/fstab; then
            echo "UUID=$NTFS_UUID /mnt/HOME auto nosuid,nodev,nofail,x-gvfs-show 0 0" >> /etc/fstab
        fi
        systemctl daemon-reload
        mount -a || echo "Mounting $NTFS_DRIVE failed — check /etc/fstab."
    else
        echo "No UUID found on $NTFS_DRIVE — skipping the NTFS mount."
    fi
else
    echo "No NTFS drive specified, skipping..."
fi

# ============================================================
# SPOTIFY (+ adblock)
# ============================================================
# Best-effort: any failure just skips Spotify.
install_spotify() {
    curl -fsSL https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/spotify.gpg || return 1
    echo "deb [signed-by=/etc/apt/keyrings/spotify.gpg] http://repository.spotify.com stable non-free" \
        > /etc/apt/sources.list.d/spotify.list
    # Drop the repo on failure so it doesn't break every later apt update.
    if ! apt-get update; then
        rm -f /etc/apt/sources.list.d/spotify.list
        apt-get update || true
        return 1
    fi
    apt-get install -y spotify-client || return 1

    apt-get install -y cargo make || return 1
    local build so
    build=$(mktemp -d) || return 1
    git clone --depth 1 https://github.com/abba23/spotify-adblock.git "$build/spotify-adblock" || return 1
    make -C "$build/spotify-adblock" || return 1
    so=$(find "$build/spotify-adblock/target/release" -maxdepth 1 -name 'lib*.so' | head -1)
    [[ -n "$so" ]] || return 1
    install -Dm755 "$so" /usr/lib/spotify-adblock.so || return 1
    install -Dm644 "$build/spotify-adblock/config.toml" /etc/spotify-adblock/config.toml || return 1
    rm -rf "$build"

    if [[ -f /usr/share/applications/spotify.desktop ]]; then
        mkdir -p /usr/local/share/applications
        cp /usr/share/applications/spotify.desktop /usr/local/share/applications/spotify.desktop
        sed -i 's|^Exec=|Exec=env LD_PRELOAD=/usr/lib/spotify-adblock.so |' \
            /usr/local/share/applications/spotify.desktop
    fi
}
echo "Installing Spotify with ad blocking..."
install_spotify || echo "Spotify/spotify-adblock install failed — skipping. (Did Spotify rotate its apt signing key? Check https://www.spotify.com/download/linux/)"

# ============================================================
# STOCK GNOME THEME (optional) — Yaru -> Adwaita
# ============================================================
# Yaru's orange folder icons are kept: they are copied into a small icon
# theme that inherits everything else from Adwaita, before Yaru is purged.
if [[ "$INSTALL_ADWAITA" != yes ]]; then
    echo "Keeping Ubuntu's Yaru theme (answered '$INSTALL_ADWAITA')."
else
    # Stock GNOME session and theme bits first, so purging Yaru (which takes
    # ubuntu-session with it) can never leave gdm3 without a session manager.
    apt-get install -y gnome-session gnome-backgrounds adwaita-icon-theme sound-theme-freedesktop
    apt-get install -y adwaita-icon-theme-legacy 2>/dev/null || true

    # Build "Adwaita-YaruFolders": Yaru's folder icons at every size, symlinks
    # resolved, on top of Yaru's own index.theme pointed at Adwaita.
    YARU_ICONS=/usr/share/icons/Yaru
    FOLDER_THEME=/usr/share/icons/Adwaita-YaruFolders
    ICON_THEME=Adwaita
    if [[ -f "$YARU_ICONS/index.theme" ]]; then
        rm -rf "$FOLDER_THEME"
        mkdir -p "$FOLDER_THEME"
        (cd "$YARU_ICONS" && find -L . \( -path '*/places/folder*' -o -path '*/places/user-home*' \
                -o -path '*/places/user-desktop*' -o -path '*/mimetypes/inode-directory*' \) -type f 2>/dev/null) \
        | while read -r f; do
            mkdir -p "$FOLDER_THEME/$(dirname "$f")"
            cp -L "$YARU_ICONS/$f" "$FOLDER_THEME/$f"
        done
        sed -e 's/^Name=.*/Name=Adwaita-YaruFolders/' \
            -e 's/^Comment=.*/Comment=Adwaita with Yaru folder icons/' \
            -e '/^Inherits=/d' \
            -e 's/^\[Icon Theme\]$/[Icon Theme]\nInherits=Adwaita,hicolor/' \
            "$YARU_ICONS/index.theme" > "$FOLDER_THEME/index.theme"
        # Create every directory the index lists so none is missing.
        grep -E '^(Scaled)?Directories=' "$FOLDER_THEME/index.theme" | cut -d= -f2- | tr ',' '\n' \
        | while read -r d; do [[ -n "$d" ]] && mkdir -p "$FOLDER_THEME/$d"; done
        gtk-update-icon-cache -q -t -f "$FOLDER_THEME" 2>/dev/null || true
        ICON_THEME=Adwaita-YaruFolders
    else
        echo "Yaru icon theme not found — folder icons will be plain Adwaita."
    fi

    # Purge every installed yaru-theme-* package (ubuntu-session goes with them).
    YARU_PKGS=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'yaru-theme-*' 2>/dev/null \
        | awk '$2 == "installed" {print $1}' | tr '\n' ' ') || YARU_PKGS=""
    if [[ -n "$YARU_PKGS" ]]; then
        echo "Purging Yaru packages: $YARU_PKGS"
        # shellcheck disable=SC2086
        apt-get purge -y $YARU_PKGS
        apt-get autoremove -y --purge
    else
        echo "No yaru-theme-* packages are installed."
    fi
    YARU_LEFT=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'yaru-theme-*' 2>/dev/null \
        | awk '$2 == "installed" {print $1}' | tr '\n' ' ') || YARU_LEFT=""
    if [[ -n "$YARU_LEFT" ]]; then
        echo "WARNING: Yaru packages still installed after purge: $YARU_LEFT"
    else
        echo "Yaru theme removed."
    fi
    # Purging yaru-theme-gnome-shell takes ubuntu-session with it; without this
    # the user's saved session type ('ubuntu') no longer exists and GDM would
    # fall back on its own, but say so explicitly.
    if [[ -f /var/lib/AccountsService/users/$USERNAME ]]; then
        sed -i 's/^XSession=ubuntu$/XSession=gnome/' "/var/lib/AccountsService/users/$USERNAME"
        sed -i 's/^Session=ubuntu$/Session=gnome/' "/var/lib/AccountsService/users/$USERNAME"
    fi

    # Keep Ubuntu's dock: the stock GNOME session doesn't enable it by itself.
    apt-get install -y gnome-shell-extension-ubuntu-dock
    as_user gnome-extensions enable ubuntu-dock@ubuntu.com \
        || echo "Could not enable ubuntu-dock — enable it in the Extensions app."

    user_gsettings org.gnome.desktop.interface gtk-theme 'Adwaita'
    user_gsettings org.gnome.desktop.interface icon-theme "$ICON_THEME"
    user_gsettings org.gnome.desktop.interface cursor-theme 'Adwaita'
    user_gsettings org.gnome.desktop.sound theme-name 'freedesktop'
fi

# ============================================================
# APP ICONS (icons/)
# ============================================================
ICON_DIR=/usr/share/icons/hicolor/scalable/apps
mkdir -p "$ICON_DIR"
cp "$REPO_DIR"/icons/*.svg "$ICON_DIR/"
# Papers (Evince's successor) reuses the Evince icon.
cp "$REPO_DIR/icons/org.gnome.Evince.svg" "$ICON_DIR/org.gnome.Papers.svg"
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

# Yaru (if kept) outranks hicolor, so point the .desktop files at the SVGs directly
# via overrides in /usr/local/share/applications. Missing .desktop files are skipped.
mkdir -p /usr/local/share/applications
declare -A ICON_OVERRIDES=(
    [org.gnome.Ptyxis.desktop]=org.gnome.Terminal.svg
    [org.gnome.Terminal.desktop]=org.gnome.Terminal.svg
    [org.gnome.Console.desktop]=org.gnome.Terminal.svg
    [org.gnome.Evince.desktop]=org.gnome.Evince.svg
    [org.gnome.Papers.desktop]=org.gnome.Evince.svg
    [org.gnome.Software.desktop]=org.gnome.Software.svg
    [org.gnome.Nautilus.desktop]=org.gnome.Nautilus.svg
)
for desktop in "${!ICON_OVERRIDES[@]}"; do
    src="/usr/share/applications/$desktop"
    [[ -f "$src" ]] || continue
    cp "$src" "/usr/local/share/applications/$desktop"
    sed -i "s|^Icon=.*|Icon=$ICON_DIR/${ICON_OVERRIDES[$desktop]}|" \
        "/usr/local/share/applications/$desktop"
done

update-desktop-database /usr/local/share/applications 2>/dev/null || true

# ============================================================
# FONTS
# ============================================================
apt-get install -y \
    fonts-noto-core fonts-noto-extra fonts-noto-color-emoji fonts-noto-cjk \
    fonts-liberation fonts-dejavu fonts-font-awesome fonts-jetbrains-mono

# Fira Sans from fonts/fira (no Debian package exists).
install -d -m 0755 /usr/share/fonts/truetype/fira
install -m 0644 "$REPO_DIR"/fonts/fira/*.ttf /usr/share/fonts/truetype/fira/
echo "Installed $(ls /usr/share/fonts/truetype/fira/*.ttf | wc -l) Fira Sans files."

# Microsoft fonts from fonts/microsoft (Calibri, Cambria, Consolas, Tahoma, Segoe icons).
install -d -m 0755 /usr/share/fonts/truetype/microsoft
install -m 0644 "$REPO_DIR"/fonts/microsoft/*.tt[cf] /usr/share/fonts/truetype/microsoft/
fc-cache -f

if fc-list : family | grep -q '^Fira Sans'; then
    echo "fontconfig sees Fira Sans: $(fc-match 'Fira Sans Book')"
else
    echo "WARNING: fontconfig does not list Fira Sans — the font settings below will fall back to the default font."
fi

user_gsettings org.gnome.desktop.interface font-name 'Fira Sans Book 12'
user_gsettings org.gnome.desktop.interface document-font-name 'Fira Sans Book 12'
user_gsettings org.gnome.desktop.wm.preferences titlebar-font 'Fira Sans Bold 12'

# ============================================================
# UBUNTU BRANDING (Plymouth splash)
# ============================================================
# Ubuntu's bgrt/spinner Plymouth theme carries the Ubuntu logo; keep it the
# default theme (it also ships the logo file the GDM greeter shows).
apt-get install -y plymouth plymouth-theme-spinner plymouth-theme-ubuntu-text
BGRT=/usr/share/plymouth/themes/bgrt/bgrt.plymouth
if [[ -f "$BGRT" ]] && [[ "$(update-alternatives --query default.plymouth 2>/dev/null | sed -n 's/^Value: //p')" != "$BGRT" ]]; then
    update-alternatives --set default.plymouth "$BGRT" && update-initramfs -u \
        || echo "Could not select the bgrt Plymouth theme — the current one stays."
fi

# ============================================================
# GDM GREETER (font + Ubuntu logo)
# ============================================================
# The login screen runs as the gdm user, so user gsettings don't reach it.
# Debian/Ubuntu's gdm3 links /etc/gdm3/greeter.dconf-defaults into
# /usr/share/gdm/dconf/ and compiles that directory into
# /var/lib/gdm3/greeter-dconf-defaults with /usr/share/gdm/generate-config
# (run when gdm starts). Edit the keyfile, then compile it right away.
GREETER=/etc/gdm3/greeter.dconf-defaults
# greeter_set SECTION KEY VALUE: replace the key, or add it under SECTION.
# --follow-symlinks keeps the file a link if the package made it one.
greeter_set() {
    local section=$1 key=$2 value=$3
    if grep -q "^$key=" "$GREETER"; then
        sed -i --follow-symlinks "s|^$key=.*|$key=$value|" "$GREETER"
    elif grep -q "^\[$section\]" "$GREETER"; then
        sed -i --follow-symlinks "\|^\[$section\]|a $key=$value" "$GREETER"
    else
        printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> "$GREETER"
    fi
}
if [[ -f "$GREETER" ]]; then
    greeter_set org/gnome/desktop/interface font-name "'Fira Sans Book 12'"
    if [[ -f /usr/share/plymouth/ubuntu-logo.png ]]; then
        greeter_set org/gnome/login-screen logo "'/usr/share/plymouth/ubuntu-logo.png'"
    else
        echo "No /usr/share/plymouth/ubuntu-logo.png — GDM logo left as is."
    fi
    echo "GDM greeter keys now set in $GREETER:"
    grep -E '^(font-name|logo)=' "$GREETER" || true

    # Compile the keyfile directory into the greeter database now, instead of
    # waiting for the next gdm start.
    if [[ -x /usr/share/gdm/generate-config ]]; then
        /usr/share/gdm/generate-config \
            && echo "Compiled the GDM greeter defaults (/var/lib/gdm3/greeter-dconf-defaults)." \
            || echo "WARNING: /usr/share/gdm/generate-config failed — GDM keeps its current font/logo."
    else
        dpkg-reconfigure gdm3 \
            || echo "WARNING: dpkg-reconfigure gdm3 failed — GDM keeps its current font/logo."
    fi
    # The greeter's own dconf database outranks the compiled defaults; make
    # sure it isn't pinning a font (it normally sets nothing).
    GDM_HOME=$(getent passwd gdm | cut -d: -f6)
    if [[ -n "$GDM_HOME" && -f "$GDM_HOME/.config/dconf/user" ]] \
        && sudo -u gdm dbus-run-session -- dconf read /org/gnome/desktop/interface/font-name 2>/dev/null | grep -q .; then
        sudo -u gdm dbus-run-session -- dconf reset /org/gnome/desktop/interface/font-name || true
    fi
else
    echo "No $GREETER — skipped the GDM greeter settings."
fi

# ============================================================
# GTK4 dGPU LAUNCH STALL
# ============================================================
# GTK's Vulkan renderer wakes the suspended NVIDIA dGPU on every GTK4 app launch.
if grep -q '^GDK_DISABLE=' /etc/environment 2>/dev/null; then
    sed -i 's/^GDK_DISABLE=.*/GDK_DISABLE=vulkan/' /etc/environment
else
    printf '\nGDK_DISABLE=vulkan\n' >> /etc/environment
fi

# ============================================================
# GNOME SHELL EXTENSION
# ============================================================
# "Disable Workspace Switcher Overlay" (extensions.gnome.org #6358).
install_ego_extension() {
    local pk=$1 shell_ver meta uuid url tmp
    shell_ver=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [[ -n "$shell_ver" ]] || return 1
    meta=$(curl -fsSL "https://extensions.gnome.org/extension-info/?pk=$pk&shell_version=$shell_ver") || return 1
    uuid=$(jq -r '.uuid // empty' <<<"$meta")
    url=$(jq -r '.download_url // empty' <<<"$meta")
    [[ -n "$uuid" && -n "$url" ]] || return 1
    tmp=$(mktemp -d) || return 1
    curl -fsSL "https://extensions.gnome.org$url" -o "$tmp/ext.zip" || return 1
    chmod 755 "$tmp" && chmod 644 "$tmp/ext.zip"
    sudo -u "$USERNAME" -H gnome-extensions install --force "$tmp/ext.zip" >&2 || return 1
    rm -rf "$tmp"
    echo "$uuid"
}
if EXT_UUID=$(install_ego_extension 6358); then
    as_user gnome-extensions enable "$EXT_UUID" \
        || echo "Installed but could not enable $EXT_UUID — enable it in the Extensions app."
else
    echo "Could not install 'Disable Workspace Switcher Overlay' (e.g.o #6358) — no build for this GNOME Shell?"
fi

# ============================================================
# DONE
# ============================================================
echo
echo "INSTALLATION COMPLETE  ($(date -Is), log: $LOG)"
echo "  Development stack : $INSTALL_DEV"
echo "  Gaming stack      : $INSTALL_GAMING"
echo "  Yaru -> Adwaita   : $INSTALL_ADWAITA"
echo "  Interface font    : $(as_user gsettings get org.gnome.desktop.interface font-name 2>/dev/null || echo unknown)"
echo "  GTK theme         : $(as_user gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || echo unknown)"
echo " - Reboot to apply the silent/fast boot changes and the GDM font/logo."
echo " - Log out and back in for the docker group, fonts and theme changes to take effect."
