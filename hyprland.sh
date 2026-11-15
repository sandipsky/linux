#!/usr/bin/env bash

set -e

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "Run this script with bash, not sh: ./hyprland.sh"
    exit 1
fi
# yay and makepkg refuse to build packages as root.
if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user (./hyprland.sh), not with sudo — it asks for the password itself." >&2
    exit 1
fi
if [[ ! -t 1 ]] || ! { : </dev/tty; } 2>/dev/null; then
    echo "This script needs an interactive terminal (it asks a question). Clone the repo and run: ./hyprland.sh"
    exit 1
fi

USERNAME=$(id -un)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$HOME/.local/share/applications"

if [[ ! -d "$REPO_DIR/config/hypr" || ! -f "$REPO_DIR/icons/folder/index.theme" || ! -d "$REPO_DIR/fonts/microsoft" || ! -f "$REPO_DIR/nautilus/folder-preview" ]]; then
    echo "config/, icons/, fonts/ and nautilus/ not found next to the script ($REPO_DIR). Run it from a full clone of the repo."
    exit 1
fi

# ============================================================
# PROMPTS
# ============================================================
read -rp "Install SDDM login screen instead of direct login into Hyprland? [y/N]: " INSTALL_SDDM </dev/tty

# ============================================================
# SUDO
# ============================================================
# One prompt up front; the keepalive outlasts sudo's 15-minute timeout.
sudo -v
( while kill -0 "$$" 2>/dev/null; do sleep 60; sudo -n -v; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT

# ============================================================
# PACKAGES
# ============================================================
# qt5-wayland and qt6-wayland let Qt apps honour QT_QPA_PLATFORM=wayland from
# config/uwsm/env; qt6-5compat carries the Qt 5 leftovers (GraphicalEffects)
# that older QML, SDDM themes included, imports. noctalia is the bar,
# launcher, lock screen, notifications, clipboard, idle, night light and
# wallpaper in one; upower is for its battery widget.
sudo pacman -S --noconfirm --needed \
    hyprland \
    hyprpicker \
    xdg-desktop-portal-hyprland \
    qt5-wayland \
    qt6-wayland \
    qt6-5compat \
    uwsm \
    noctalia \
    upower \
    wl-clipboard \
    grim \
    slurp \
    brightnessctl \
    blueman \
    luajit \
    alacritty \
    nautilus \
    nautilus-python \
    python-pillow \
    gnome-calculator \
    evince \
    loupe \
    file-roller \
    gnome-text-editor \
    gnome-themes-extra \
    adwaita-icon-theme \
    fastfetch

# ============================================================
# CLAUDE CODE
# ============================================================
# Best effort. stdin from /dev/null: the installer is written for `curl | bash`
# and must never block waiting for terminal input.
CLAUDE_INSTALLER=$(mktemp)
if curl -fsSL https://claude.ai/install.sh -o "$CLAUDE_INSTALLER"; then
    bash "$CLAUDE_INSTALLER" </dev/null \
        || echo "WARNING: the Claude Code installer failed; rerun later with: curl -fsSL https://claude.ai/install.sh | bash"
else
    echo "WARNING: could not download the Claude Code installer; rerun later with: curl -fsSL https://claude.ai/install.sh | bash"
fi
rm -f "$CLAUDE_INSTALLER"

# ============================================================
# CONFIG (config/ -> ~/.config)
# ============================================================
# Noctalia's config.toml holds only the overrides; what is changed in its
# Settings window lands in ~/.local/state/noctalia/settings.toml on top.
mkdir -p "$HOME/.config"
cp -r "$REPO_DIR"/config/* "$HOME/.config/"

# fastfetch's logo path carries an absolute path.
sed -i "s|USERNAME|$USERNAME|g" "$HOME/.config/fastfetch/config.jsonc"

ZSHRC="$HOME/.zshrc"
if ! grep -q 'fastfetch' "$ZSHRC" 2>/dev/null; then
    tee -a "$ZSHRC" >/dev/null <<'EOF'

# system summary on every new interactive terminal (skipped when output is not a tty or inside the VS Code terminal)
[[ -t 1 && "$TERM_PROGRAM" != vscode ]] && command -v fastfetch >/dev/null && fastfetch
EOF
fi

# ============================================================
# AC POWER PROFILE SWITCHING
# ============================================================
# udev runs as root, so the user services are started via --machine.
POWER_RULE=/etc/udev/rules.d/99-power.rules
sudo tee "$POWER_RULE" >/dev/null <<EOF
# Written by hyprland.sh: start the user's acpoweron/acpoweroff services
# (~/.config/systemd/user/) when the charger is plugged in or pulled.
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/systemctl --no-block --machine=$USERNAME@.host --user start acpoweron.service"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/systemctl --no-block --machine=$USERNAME@.host --user start acpoweroff.service"
EOF
sudo udevadm control --reload

# ============================================================
# GTK4 dGPU LAUNCH STALL
# ============================================================
# GTK's Vulkan renderer enumerates every GPU at startup, waking the suspended
# dGPU (~1.5 s stall per GTK4 launch). /etc/environment also covers
# dbus-activated apps, which environment.lua would miss. The leading \n keeps
# the entry intact if the file lacks a trailing newline.
if grep -q '^GDK_DISABLE=' /etc/environment 2>/dev/null; then
    sudo sed -i 's/^GDK_DISABLE=.*/GDK_DISABLE=vulkan/' /etc/environment
else
    printf '\nGDK_DISABLE=vulkan\n' | sudo tee -a /etc/environment >/dev/null
fi

# ============================================================
# BLUETOOTH
# ============================================================
# Adapter off at boot; the bar widget toggles it.
if [[ -f /etc/bluetooth/main.conf ]]; then
    if grep -q '^#*AutoEnable=' /etc/bluetooth/main.conf; then
        sudo sed -i 's/^#*AutoEnable=.*/AutoEnable=false/' /etc/bluetooth/main.conf
    else
        printf '\n[Policy]\nAutoEnable=false\n' | sudo tee -a /etc/bluetooth/main.conf >/dev/null
    fi
fi

# systemd-rfkill persists soft blocks across reboots and BlueZ can't power a
# blocked adapter, so the bar's toggle would silently fail. Clear it every boot.
sudo tee /etc/systemd/system/bluetooth-rfkill-unblock.service >/dev/null <<'EOF'
[Unit]
Description=Clear persisted Bluetooth rfkill soft block
After=systemd-rfkill.service

[Service]
Type=oneshot
ExecStart=/usr/bin/rfkill unblock bluetooth

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable bluetooth-rfkill-unblock.service

# ============================================================
# APP ICONS (icons/)
# ============================================================
ICON_DIR=/usr/share/icons/hicolor/scalable/apps
sudo mkdir -p "$ICON_DIR"
sudo cp "$REPO_DIR"/icons/*.svg "$ICON_DIR/"
sudo gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

# ============================================================
# FOLDER ICONS (icons/folder)
# ============================================================
# Yaru's orange folder icons as a tiny theme that Inherits Adwaita. Its own
# theme, not hicolor: Adwaita ships folder icons and is looked up first.
FOLDER_THEME_DIR=/usr/share/icons/Yaru-folders
sudo rm -rf "$FOLDER_THEME_DIR"
sudo cp -r "$REPO_DIR/icons/folder" "$FOLDER_THEME_DIR"
sudo chown -R root:root "$FOLDER_THEME_DIR"
sudo chmod -R u=rwX,go=rX "$FOLDER_THEME_DIR"
sudo gtk-update-icon-cache -q -t -f "$FOLDER_THEME_DIR" 2>/dev/null || true

# ============================================================
# FONTS (fonts/microsoft)
# ============================================================
# The Microsoft fonts have no package; the rest come from archlinux.sh.
sudo install -d -m 0755 /usr/share/fonts/microsoft
sudo install -m 0644 "$REPO_DIR"/fonts/microsoft/*.tt[cf] /usr/share/fonts/microsoft/
sudo fc-cache -f

# ============================================================
# LAUNCHER CLEANUP
# ============================================================
# Swap archlinux.sh's placeholders for NoDisplay copies of the now-installed
# entries, so MIME associations still resolve. Same key placement as there.
for dest in "$APPS_DIR"/*.desktop; do
    [[ -f "$dest" ]] && grep -q '^# placeholder by archlinux.sh' "$dest" || continue
    src="/usr/share/applications/$(basename "$dest")"
    [[ -f "$src" ]] || continue
    cp "$src" "$dest"
    if grep -q '^Actions=' "$dest"; then
        sed -i -e '/^Actions=/i # hidden by archlinux.sh' -e '/^Actions=/i NoDisplay=true' "$dest"
    else
        printf '# hidden by archlinux.sh\nNoDisplay=true\n' >> "$dest"
    fi
    echo "hidden from launcher: $(basename "$dest")"
done

# ============================================================
# ALACRITTY AS "TERMINAL"
# ============================================================
# User-level copy (same id, so it outranks the system entry) renamed to
# Terminal, icon by absolute path so no icon theme can shadow it.
if [[ -f /usr/share/applications/Alacritty.desktop ]]; then
    cp /usr/share/applications/Alacritty.desktop "$APPS_DIR/Alacritty.desktop"
    # Only the first Name=; the "New Terminal" action keeps its own.
    sed -i -e '0,/^Name=/s/^Name=.*/Name=Terminal/' \
           -e "s|^Icon=.*|Icon=$ICON_DIR/org.gnome.Terminal.svg|" \
           "$APPS_DIR/Alacritty.desktop"
else
    echo "WARNING: /usr/share/applications/Alacritty.desktop not found — launcher entry left as is"
fi

update-desktop-database "$APPS_DIR" 2>/dev/null || true

# ============================================================
# NAUTILUS EXTENSIONS (nautilus/)
# ============================================================
# open-in.py: "Open in Code" and "Open in Terminal" in the right-click menu.
# folder-preview.py: folder icons previewing the first image inside, drawn by
# ~/.local/bin/folder-preview (Pillow) into ~/.cache/folder-previews.
NAUTILUS_EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
mkdir -p "$NAUTILUS_EXT_DIR"
cp "$REPO_DIR"/nautilus/*.py "$NAUTILUS_EXT_DIR/"
install -Dm755 "$REPO_DIR/nautilus/folder-preview" "$HOME/.local/bin/folder-preview"

# ============================================================
# DESKTOP SETTINGS
# ============================================================
# Qt apps are scaled and get Fira Sans through config/uwsm/env and fontconfig,
# no per-app overrides. The Nautilus sort key is set for GTK 3 too: on first
# start Nautilus copies the GTK 3 value over the GTK 4 one.
dbus-run-session -- bash <<'EOF'
gsettings set org.gnome.desktop.interface gtk-theme "Adwaita-dark"
gsettings set org.gnome.desktop.interface icon-theme 'Yaru-folders'
gsettings set org.gnome.desktop.interface font-name 'Fira Sans Book 12'
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.privacy remember-recent-files false
gsettings set org.gnome.nautilus.list-view use-tree-view true
gsettings set org.gnome.nautilus.preferences show-create-link true
gsettings set org.gnome.nautilus.preferences show-delete-permanently true
gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true
gsettings set org.gtk.Settings.FileChooser sort-directories-first true
gsettings set org.gnome.TextEditor use-system-font false
gsettings set org.gnome.TextEditor custom-font 'JetBrains Mono 13'
gsettings set org.gnome.TextEditor show-line-numbers true
gsettings set org.gnome.TextEditor highlight-current-line true
EOF

xdg-mime default org.gnome.Loupe.desktop image/jpeg
xdg-mime default org.gnome.Loupe.desktop image/png
xdg-mime default org.gnome.Loupe.desktop image/webp

xdg-mime default org.gnome.TextEditor.desktop text/plain
xdg-mime default org.gnome.TextEditor.desktop application/x-shellscript

# LibreOffice Draw would otherwise grab application/pdf.
xdg-mime default org.gnome.Evince.desktop application/pdf

# ~/.face is Noctalia's avatar_path and what the SDDM greeter shows.
if [[ -f "$REPO_DIR/profile.png" ]]; then
    cp "$REPO_DIR/profile.png" "$HOME/.face"
fi

# ============================================================
# GPU DETECTION (hybrid Intel + NVIDIA)
# ============================================================
IGPU_PCI="" IGPU_BUSID="" HAS_NVIDIA=""
for dev in /sys/bus/pci/devices/*; do
    [[ "$(cat "$dev/class")" == 0x03* ]] || continue
    if [[ "$(cat "$dev/vendor")" == 0x10de ]]; then
        HAS_NVIDIA=1
    elif [[ "$(cat "$dev/boot_vga" 2>/dev/null)" == 1 ]]; then
        IGPU_PCI="${dev##*/}"
        # 0000:00:02.0 -> PCI:0:2:0 (Xorg wants decimal bus:device:function)
        IFS=':.' read -r _ bus slot func <<<"$IGPU_PCI"
        IGPU_BUSID="PCI:$((16#$bus)):$((16#$slot)):$func"
    fi
done

# ============================================================
# HYPRLAND ON THE iGPU ONLY
# ============================================================
# config/uwsm/env points AQ_DRM_DEVICES at /dev/dri/igpu when it exists, so
# Hyprland never opens the dGPU. A stable name: card0/card1 can swap between
# boots, and the by-path names contain colons, AQ_DRM_DEVICES's separator.
IGPU_RULE=/etc/udev/rules.d/70-igpu-symlink.rules
if [[ -n "$HAS_NVIDIA" && -n "$IGPU_PCI" ]]; then
    sudo tee "$IGPU_RULE" >/dev/null <<EOF
# Written by hyprland.sh: stable /dev/dri/igpu name for the iGPU, used by
# AQ_DRM_DEVICES in ~/.config/uwsm/env. ENV{DEVNAME} keeps the connector
# objects (card1-eDP-1, ...) out: they match card* but have no device node.
KERNEL=="card*", SUBSYSTEM=="drm", ENV{DEVNAME}=="/dev/dri/card*", KERNELS=="$IGPU_PCI", SYMLINK+="dri/igpu"
EOF
else
    sudo rm -f "$IGPU_RULE"
fi
sudo udevadm control --reload

# ============================================================
# LOGIN: SDDM or direct login
# ============================================================
# Default is tty1 autologin + uwsm from the login profile; with SDDM, sddm
# takes tty1 instead. Each branch undoes the other's pieces, so a re-run that
# switches the answer takes effect at the reboot below.
GETTY_OVERRIDE=/etc/systemd/system/getty@tty1.service.d/override.conf
AUTOSTART_BEGIN='# >>> hyprland.sh: uwsm autostart on tty1 >>>'
AUTOSTART_END='# <<< hyprland.sh: uwsm autostart on tty1 <<<'
if [[ "$INSTALL_SDDM" =~ ^[Yy] ]]; then
    FACES_DIR=/usr/share/sddm/faces
    STATE_FILE=/var/lib/sddm/state.conf
    UWSM_SESSION=/usr/share/wayland-sessions/hyprland-uwsm.desktop

    sudo pacman -S --noconfirm --needed sddm

    # Left to autoconfigure, the greeter's Xorg (alive for the whole session)
    # also opens the NVIDIA dGPU and keeps it out of runtime D3. Give it a config
    # that drives only the iGPU; only SDDM's X server reads it.
    SDDM_XORG_CONF=/etc/X11/sddm-igpu.conf
    if [[ -n "$HAS_NVIDIA" && -n "$IGPU_BUSID" ]]; then
        sudo tee "$SDDM_XORG_CONF" >/dev/null <<EOF
# Written by hyprland.sh: SDDM's greeter Xorg (started with -config pointing
# here, see /etc/sddm.conf.d/zz-hyprland.conf) drives only the iGPU, so it
# doesn't keep the NVIDIA dGPU awake for the whole session.
Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection

Section "Device"
    Identifier "iGPU"
    Driver     "modesetting"
    BusID      "$IGPU_BUSID"
EndSection
EOF
        SDDM_X11_ARGS="-nolisten tcp -config $SDDM_XORG_CONF"
    else
        sudo rm -f "$SDDM_XORG_CONF"
        SDDM_X11_ARGS="-nolisten tcp"
    fi

    # Drop-ins in /etc/sddm.conf.d are read in name order, so zz- keeps this on
    # top. No [Theme] section: SDDM's default greeter.
    sudo mkdir -p /etc/sddm.conf.d
    sudo tee /etc/sddm.conf.d/zz-hyprland.conf >/dev/null <<EOF
[X11]
ServerArguments=$SDDM_X11_ARGS
EOF

    # The greeter can't read ~/.face inside a 0700 home.
    if [[ -f "$REPO_DIR/profile.png" ]]; then
        sudo install -Dm644 "$REPO_DIR/profile.png" "$FACES_DIR/$USERNAME.face.icon"
    fi

    # Preselect the user and the uwsm session; an existing state file is SDDM's
    # remembered choice.
    if sudo test -f "$STATE_FILE"; then
        echo "$STATE_FILE exists — leaving SDDM's remembered choice alone"
    elif [[ ! -f "$UWSM_SESSION" ]]; then
        echo "$UWSM_SESSION not found — skipping the session preselect"
    else
        sudo mkdir -p "$(dirname "$STATE_FILE")"
        sudo tee "$STATE_FILE" >/dev/null <<EOF
[Last]
Session=$UWSM_SESSION
User=$USERNAME
EOF
        if id sddm >/dev/null 2>&1; then
            sudo chown -R sddm:sddm "$(dirname "$STATE_FILE")"
        fi
    fi

    # Undo an earlier direct-login run.
    if sudo test -f "$GETTY_OVERRIDE"; then
        sudo rm -f "$GETTY_OVERRIDE"
        sudo rmdir "$(dirname "$GETTY_OVERRIDE")" 2>/dev/null || true
        sudo systemctl daemon-reload
    fi
    for f in "$HOME/.zprofile" "$HOME/.bash_profile"; do
        if [[ -f "$f" ]] && grep -qF "$AUTOSTART_BEGIN" "$f"; then
            sed -i "/^$AUTOSTART_BEGIN\$/,/^$AUTOSTART_END\$/d" "$f"
        fi
    done

    sudo systemctl enable sddm.service
else
    # Undo an earlier SDDM run.
    if systemctl is-enabled -q sddm.service 2>/dev/null; then
        sudo systemctl disable sddm.service
    fi

    sudo mkdir -p "$(dirname "$GETTY_OVERRIDE")"
    sudo tee "$GETTY_OVERRIDE" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --skip-login --nonewline --noissue --noclear %I \$TERM
Type=idle
EOF

    LOGIN_SHELL=$(getent passwd "$USERNAME" | cut -d: -f7)
    if [[ "$(basename "$LOGIN_SHELL")" == "zsh" ]]; then
        AUTOSTART_PROFILE="$HOME/.zprofile"
    else
        AUTOSTART_PROFILE="$HOME/.bash_profile"
    fi
    if [[ -f "$AUTOSTART_PROFILE" ]]; then
        sed -i "/^$AUTOSTART_BEGIN\$/,/^$AUTOSTART_END\$/d" "$AUTOSTART_PROFILE"
    fi
    tee -a "$AUTOSTART_PROFILE" >/dev/null <<EOF
$AUTOSTART_BEGIN
if [[ -z "\$WAYLAND_DISPLAY" && "\$(tty)" == "/dev/tty1" ]]; then
    if uwsm check may-start; then
        exec uwsm start hyprland.desktop >/dev/null 2>&1
    fi
fi
$AUTOSTART_END
EOF
fi

# ============================================================
# DONE
# ============================================================
# Put the sudo password prompt back (archlinux.sh left wheel passwordless) and
# reboot in the same sudo call: afterwards a separate sudo would ask again.
sudo bash -c "sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers && systemctl reboot"
