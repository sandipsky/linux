#!/usr/bin/env bash

set -e

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "Run this script with bash, not sh: ./hyprland.sh"
    exit 1
fi
# System-level steps use sudo, but the script itself must run as the normal
# user — yay and makepkg refuse to build packages as root.
if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user (./hyprland.sh), not with sudo — it asks for the password itself." >&2
    exit 1
fi
# The prompt is read from the terminal, so `curl ... | bash` can't work.
if [[ ! -t 1 ]] || ! { : </dev/tty; } 2>/dev/null; then
    echo "This script needs an interactive terminal (it asks a question). Clone the repo and run: ./hyprland.sh"
    exit 1
fi

USERNAME=$(id -un)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$HOME/.local/share/applications"

if [[ ! -d "$REPO_DIR/config/hypr" || ! -d "$REPO_DIR/sddm-themes/Elegant" || ! -f "$REPO_DIR/icons/folder/index.theme" || ! -d "$REPO_DIR/fonts/microsoft" || ! -f "$REPO_DIR/nautilus/folder-preview" ]]; then
    echo "config/, sddm-themes/, icons/, fonts/ and nautilus/ not found next to the script ($REPO_DIR). Run it from a full clone of the repo."
    exit 1
fi

# ============================================================
# PROMPTS
# ============================================================
# All interactive input happens here, before the long unattended run.
read -rp "Install SDDM login screen (Elegant theme) instead of direct login into Hyprland? [y/N]: " INSTALL_SDDM </dev/tty

# ============================================================
# SUDO
# ============================================================
# Ask for the sudo password once, up front, and keep the credential cache
# fresh in the background — the pacman/yay/makepkg steps outlast sudo's
# 15-minute timeout, and a mid-run re-prompt would stall the install.
sudo -v
( while kill -0 "$$" 2>/dev/null; do sleep 60; sudo -n -v; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT

# ============================================================
# PACKAGES
# ============================================================
# Compositor and session (uwsm), Wayland utilities, the GNOME apps used with
# it, and the Adwaita GTK/icon themes (adwaita-icon-theme pulls in
# adwaita-cursors, the cursor theme config/uwsm/env and gtk-3.0/settings.ini
# select). Adwaita's grey folder icons are swapped for Yaru's orange ones in
# the FOLDER ICONS step below. luajit runs the Lua Hyprland config.
# nautilus-python and python-pillow run the Nautilus extensions from the
# NAUTILUS EXTENSIONS step.
sudo pacman -S --noconfirm --needed \
    hyprland \
    hyprpicker \
    hyprsunset \
    xdg-desktop-portal-hyprland \
    uwsm \
    wl-clipboard \
    cliphist \
    wtype \
    grim \
    slurp \
    brightnessctl \
    polkit-gnome \
    blueman \
    jq \
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
curl -fsSL https://claude.ai/install.sh | bash

# ============================================================
# HYPR-SHELL
# ============================================================
# hypr-shell — the GTK4 bar/shell (bar, launcher, control center,
# notifications, lock/idle, night light, wallpaper, OSDs). Cloned fresh from
# its GitHub repo into a temp dir and built from there — the repo moves too
# fast to keep a vendored snapshot in sync. Its own install.sh installs the
# pacman build deps it is missing (gtkmm-4.0, gtk4-layer-shell, libadwaita,
# ...) and builds into ~/.local (binaries, icon fonts, desktop entry);
# autostart.lua and the keybinds call /home/$USERNAME/.local/bin/hypr-shell by
# absolute path. The throwaway clone is removed afterwards; the dev checkout
# at ~/Projects/hypr-shell is cloned by hand later — deliberately not part of
# this script.
HYPR_SHELL_REPO=https://github.com/sandipsky/hypr-shell
BUILD_DIR=$(mktemp -d)
git clone --depth 1 "$HYPR_SHELL_REPO" "$BUILD_DIR/hypr-shell"
# Run through bash rather than ./install.sh: the repo tracks it as 100644, so
# the clone has no exec bit.
if [[ ! -f "$BUILD_DIR/hypr-shell/install.sh" ]]; then
    echo "ERROR: $HYPR_SHELL_REPO has no install.sh — nothing to build." >&2
    exit 1
fi
(cd "$BUILD_DIR/hypr-shell" && bash ./install.sh)
rm -rf "${BUILD_DIR:?}"

# ============================================================
# CONFIG (config/ -> ~/.config)
# ============================================================
# Hyprland (Lua), hypr-shell, uwsm session env, alacritty, fastfetch, vim,
# gtk-3.0 settings, fontconfig and the AC-power user services.
mkdir -p "$HOME/.config"
cp -r "$REPO_DIR"/config/* "$HOME/.config/"

# The Hyprland Lua config, hypr-shell's config.json and fastfetch's logo path
# carry absolute paths.
for f in hypr/conf/keybinds.lua hypr/conf/autostart.lua hypr-shell/config.json fastfetch/config.jsonc; do
    sed -i "s|USERNAME|$USERNAME|g" "$HOME/.config/$f"
done
# hypr-shell's bar presets carry the same absolute paths (any *.json shipped).
find "$HOME/.config/hypr-shell/presets" -name '*.json' -exec sed -i "s|USERNAME|$USERNAME|g" {} +

# fastfetch on every new interactive terminal. ~/.zshrc itself is written by
# archlinux.sh, so only append the block if it isn't there yet.
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
# config/systemd/user/acpoweron.service and acpoweroff.service switch the
# power profile, brightness and the panel's refresh rate with the charger.
# udev runs as root, so it starts them in the user's manager via --machine.
sudo tee /etc/udev/rules.d/99-power.rules >/dev/null <<EOF
# Written by hyprland.sh: start the user's acpoweron/acpoweroff services
# (~/.config/systemd/user/) when the charger is plugged in or pulled.
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/systemctl --no-block --machine=$USERNAME@.host --user start acpoweron.service"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/systemctl --no-block --machine=$USERNAME@.host --user start acpoweroff.service"
EOF
sudo udevadm control --reload

# ============================================================
# GTK4 dGPU LAUNCH STALL
# ============================================================
# GTK's Vulkan renderer (4.16+) enumerates every GPU at startup, waking the
# runtime-suspended NVIDIA dGPU — an ~1.5 s stall on each GTK4 app launch even
# though rendering happens on the Intel iGPU. /etc/environment (PAM) covers
# the whole session — Hyprland, its children, AND dbus-/systemd-activated
# apps — so this is the single place the fix lives (not environment.lua,
# which would miss the dbus-activated ones).
# Replace-or-append so a stale hand-set value gets corrected on re-runs; the
# leading \n keeps the entry intact even if the file lacks a trailing newline.
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

# systemd-rfkill persists rfkill soft blocks across reboots (e.g. one left by
# an airplane-mode toggle), and BlueZ can't power a blocked adapter — the bar
# widget's Bluetooth toggle would silently fail forever. Clear the block every
# boot; the adapter still stays off until toggled (AutoEnable=false above).
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
# Nautilus (and every GTK file chooser) shows Ubuntu's orange Yaru folders
# instead of Adwaita's grey ones. icons/folder is a tiny icon theme that
# carries only Yaru's places/ folder PNGs (folder, folder-open, the XDG user
# dirs, user-home, user-desktop, ...) at every size and Inherits Adwaita, so
# every other icon still comes from Adwaita. It is installed as its own
# theme rather than into hicolor: Adwaita ships folder icons of its own, and
# the lookup walks the selected theme first, then its parents, so hicolor
# would never win. The DESKTOP SETTINGS step below selects it (gsettings),
# as does config/gtk-3.0/settings.ini for GTK3.
FOLDER_THEME_DIR=/usr/share/icons/Yaru-folders
sudo rm -rf "$FOLDER_THEME_DIR"
sudo cp -r "$REPO_DIR/icons/folder" "$FOLDER_THEME_DIR"
sudo chown -R root:root "$FOLDER_THEME_DIR"
sudo chmod -R u=rwX,go=rX "$FOLDER_THEME_DIR"
sudo gtk-update-icon-cache -q -t -f "$FOLDER_THEME_DIR" 2>/dev/null || true

# ============================================================
# FONTS (fonts/microsoft)
# ============================================================
# Fira Sans, JetBrains Mono and the Noto family come from archlinux.sh;
# the Microsoft fonts (Calibri, Cambria, Consolas, Tahoma, Segoe icons) have
# no package.
sudo install -d -m 0755 /usr/share/fonts/microsoft
sudo install -m 0644 "$REPO_DIR"/fonts/microsoft/*.tt[cf] /usr/share/fonts/microsoft/
sudo fc-cache -f

# ============================================================
# LAUNCHER CLEANUP
# ============================================================
# archlinux.sh hid the launcher entries of packages that weren't installed
# yet (blueman, file-roller, uwsm, ...) with placeholder files in
# ~/.local/share/applications. Now that they are in, swap each placeholder
# for a NoDisplay copy of the real entry so MIME associations still resolve
# (e.g. "Open With -> Archive Manager"). Same key placement as archlinux.sh's
# hide_desktop_entry: before any Actions= line, as the last key of
# [Desktop Entry].
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
# A user-level copy of Alacritty.desktop (same id, so it outranks the system
# entry in the launcher, the bar and "Open in Terminal") renamed to Terminal,
# with the Terminal icon from icons/ (installed above) by absolute path, so
# no icon theme can shadow it.
if [[ -f /usr/share/applications/Alacritty.desktop ]]; then
    cp /usr/share/applications/Alacritty.desktop "$APPS_DIR/Alacritty.desktop"
    # Only the first Name= (the [Desktop Entry] one); the "New Terminal"
    # action below it keeps its name.
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
# nautilus-python loads every .py in its extensions dir at startup:
# - open-in.py: "Open in Code" (VS Code, installed by archlinux.sh) and "Open
#   in Terminal" (Alacritty) in the right-click menu of the folder background
#   and of a selected folder; selected files get "Open in Code" only. Nautilus
#   has no "Open in Terminal" of its own (that used to come from
#   gnome-terminal's extension).
# - folder-preview.py: folder icons that preview the first image inside,
#   drawn into the Yaru folder from the FOLDER ICONS step the way Windows
#   Explorer and Dolphin show folders. It hands the folders Nautilus shows to
#   ~/.local/bin/folder-preview, which draws the previews with Pillow into
#   ~/.cache/folder-previews and sets them as the folders' custom icons.
#   Images added to or removed from a folder show on its icon once that
#   folder has been opened, or after F5 in the folder that contains it.
NAUTILUS_EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
mkdir -p "$NAUTILUS_EXT_DIR"
cp "$REPO_DIR"/nautilus/*.py "$NAUTILUS_EXT_DIR/"
install -Dm755 "$REPO_DIR/nautilus/folder-preview" "$HOME/.local/bin/folder-preview"

# ============================================================
# DESKTOP SETTINGS
# ============================================================
# Qt apps (OBS, qBittorrent, VirtualBox, VLC) are scaled to 125% globally via
# QT_SCALE_FACTOR in config/uwsm/env (uwsm exports it into the systemd user
# environment, so it reaches apps however they are launched — Hyprland's own
# `env` only covers its direct children) and get Fira Sans via
# config/fontconfig/conf.d/50-hypr-shell-sans-serif.conf — no per-app
# .desktop overrides.
#
# Nautilus: expandable folders in list view, "Create Link" and "Delete
# Permanently" in the right-click menu, and folders sorted before files.
# The sort key is set for GTK 3 too, not just GTK 4: on its first start
# Nautilus copies the GTK 3 value (default false) over the GTK 4 one
# (migrated-gtk-settings), and the GTK 3 file chooser then matches as well.
#
# Text Editor: JetBrains Mono 13 (installed by archlinux.sh) instead of the
# system font, line numbers and the current line highlighted.
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

# PDFs always open in Evince, whether or not LibreOffice was installed by
# archlinux.sh (LibreOffice Draw registers itself for application/pdf and
# would otherwise grab the association).
xdg-mime default org.gnome.Evince.desktop application/pdf

# Account picture for hypr-shell's lock screen and the SDDM greeter, if the
# repo carries one (profile.png next to this script).
if [[ -f "$REPO_DIR/profile.png" ]]; then
    cp "$REPO_DIR/profile.png" "$HOME/.face"
fi

# ============================================================
# LOGIN: SDDM (Elegant theme) or direct login
# ============================================================
# Default is direct login: tty1 autologin via an agetty override, then the
# login profile execs Hyprland through uwsm. With SDDM chosen, sddm takes
# over tty1 (sddm.service conflicts with getty@tty1.service) and the two
# direct-login pieces are not written. Nothing is started live either way:
# it takes effect at the reboot below.
if [[ "$INSTALL_SDDM" =~ ^[Yy] ]]; then
    THEME=Elegant
    THEME_DIR=/usr/share/sddm/themes/Elegant
    THEME_SRC="$REPO_DIR/sddm-themes/Elegant"
    FACES_DIR=/usr/share/sddm/faces
    STATE_FILE=/var/lib/sddm/state.conf
    UWSM_SESSION=/usr/share/wayland-sessions/hyprland-uwsm.desktop

    # qt6-5compat: the theme's blur/glow effects come from
    # Qt5Compat.GraphicalEffects (ported from Qt5's QtGraphicalEffects, see
    # the imports in sddm-themes/Elegant/*.qml). The theme renders in Fira
    # Sans (installed by archlinux.sh); icons come from the Tabler icon font
    # bundled in its fonts/. The greeter's cursor is Adwaita, Qt's default,
    # so no cursor setup is needed.
    sudo pacman -S --noconfirm --needed sddm
    sudo pacman -S --noconfirm --needed --asdeps qt6-5compat

    # Install the theme, keeping what hypr-shell-settings' "Login screen"
    # page may have written into the theme dir on an earlier run
    # (theme.conf.user and a copied background image).
    KEEP=$(mktemp -d)
    for f in "$THEME_DIR"/theme.conf.user "$THEME_DIR"/background.*; do
        [[ -f "$f" ]] && sudo cp -p "$f" "$KEEP/"
    done
    sudo rm -rf /usr/share/sddm/themes/Elegant
    sudo mkdir -p /usr/share/sddm/themes
    sudo cp -r "$THEME_SRC" "$THEME_DIR"
    for f in "$KEEP"/*; do
        [[ -f "$f" ]] && sudo cp -p "$f" "$THEME_DIR/"
    done
    sudo rm -rf "${KEEP:?}"
    sudo chown -R root:root "$THEME_DIR"
    sudo chmod -R u=rwX,go=rX "$THEME_DIR"

    # The theme derives its colours from hypr-shell's accent (same maths as
    # the shell's palette.hpp), so the greeter matches the desktop. Take it
    # from the config copied above; theme.conf.user overrides theme.conf
    # without touching the vendored file, and also holds the "Login screen"
    # page's settings (single [General] section) — only the accent key is
    # touched, replace-or-append.
    USER_CONF="$THEME_DIR/theme.conf.user"
    ACCENT=$(jq -r '.ui.accent // empty' "$HOME/.config/hypr-shell/config.json" 2>/dev/null || true)
    if [[ "$ACCENT" =~ ^#[0-9a-fA-F]{6}$ ]]; then
        if sudo test -f "$USER_CONF" && sudo grep -q '^accent=' "$USER_CONF"; then
            sudo sed -i "s|^accent=.*|accent=$ACCENT|" "$USER_CONF"
        elif sudo test -f "$USER_CONF"; then
            printf 'accent=%s\n' "$ACCENT" | sudo tee -a "$USER_CONF" >/dev/null
        else
            printf '[General]\naccent=%s\n' "$ACCENT" | sudo tee "$USER_CONF" >/dev/null
        fi
    else
        echo "no ui.accent in hypr-shell's config.json — the theme's default applies"
    fi

    # Select the theme. Arch ships no /etc/sddm.conf; drop-ins in
    # /etc/sddm.conf.d are read in name order with later files winning, and
    # the name has to sort after the kde_settings.conf archlinux.sh writes
    # when KDE was chosen too.
    sudo mkdir -p /etc/sddm.conf.d
    sudo tee /etc/sddm.conf.d/zz-hyprland.conf >/dev/null <<EOF
[Theme]
Current=$THEME
EOF

    # The greeter runs as the sddm user and can't read ~/.face inside a 0700
    # home, so the avatar goes to /usr/share/sddm/faces/.
    if [[ -f "$REPO_DIR/profile.png" ]]; then
        sudo install -Dm644 "$REPO_DIR/profile.png" "$FACES_DIR/$USERNAME.face.icon"
    fi

    # Preselect the user and the uwsm-managed Hyprland session, so the first
    # login matches what the tty path launches. An existing state file is
    # SDDM's remembered choice — leave it alone.
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

    sudo systemctl enable sddm.service
else
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --skip-login --nonewline --noissue --noclear %I \$TERM
Type=idle
EOF

    # archlinux.sh made zsh the login shell, so this is normally ~/.zprofile.
    LOGIN_SHELL=$(getent passwd "$USERNAME" | cut -d: -f7)
    if [[ "$(basename "$LOGIN_SHELL")" == "zsh" ]]; then
        AUTOSTART_PROFILE="$HOME/.zprofile"
    else
        AUTOSTART_PROFILE="$HOME/.bash_profile"
    fi
    tee "$AUTOSTART_PROFILE" >/dev/null <<'EOF'
if [[ -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
    if uwsm check may-start; then
        exec uwsm start hyprland.desktop >/dev/null 2>&1
    fi
fi
EOF
fi

# ============================================================
# DONE
# ============================================================
# archlinux.sh left wheel passwordless for the unattended steps; ask for the
# password again from here on.
sudo sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sudo reboot
