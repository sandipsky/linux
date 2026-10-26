#!/usr/bin/env bash
# Fresh Arch Linux install (systemd-boot, Intel + NVIDIA laptop; NVIDIA is
# skipped when running in a VM).
set -e

# ============================================================
# PROMPTS
# ============================================================
read -p "EFI partition (e.g. /dev/nvme0n1p1): " EFI
read -p "ROOT partition (e.g. /dev/nvme0n1p2): " ROOT
read -p "Enter NTFS D Drive partition (optional, e.g. /dev/nvme1n1p1, blank to skip): " NTFS_DRIVE
read -p "Username: " USER
read -p "Full Name: " NAME
read -p "Password: " PASSWORD
read -p "Install the development stack (node, JDK, Angular CLI, Docker, Postman)? [Y/n]: " INSTALL_DEV
read -p "Install the gaming stack (wine-staging, lutris)? [Y/n]: " INSTALL_GAMING
read -p "Install the KDE Plasma desktop (minimal: Dolphin, Konsole, Ark, Gwenview, Okular, KWrite, Spectacle)? [Y/n]: " INSTALL_KDE
read -p "Install LibreOffice (only Writer, Calc, Impress in the launcher)? [Y/n]: " INSTALL_OFFICE
read -p "Install the Plymouth boot splash (default theme, no distro logo)? [Y/n]: " INSTALL_PLYMOUTH
read -p "Install VirtualBox (VM host + dkms modules + guest-additions ISO)? [Y/n]: " INSTALL_VBOX

# ============================================================
# FILESYSTEM
# ============================================================
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

mount -o noatime "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# ============================================================
# MIRRORS
# ============================================================
# The live ISO ships a worldwide, unranked mirrorlist, so pacstrap often
# pulls from a mirror half a planet away. Rank nearby HTTPS mirrors by
# measured download rate with reflector (on the ISO), and pin the Nepali
# mirror at the top since this machine lives in Nepal. pacstrap copies this
# mirrorlist into the installed system, so it is ranked once here and the
# chroot inherits it. Falls back to a static regional list if reflector
# can't reach archlinux.org.
NEPAL_MIRROR='Server = https://mirrors.nepalicloud.com/archlinux/$repo/os/$arch'
if reflector --country Nepal,India,Bangladesh,Singapore --protocol https \
        --completion-percent 100 --age 12 --sort rate \
        --save /etc/pacman.d/mirrorlist.reflector; then
    { echo "$NEPAL_MIRROR"
      grep -v -F "$NEPAL_MIRROR" /etc/pacman.d/mirrorlist.reflector
    } > /etc/pacman.d/mirrorlist
    rm /etc/pacman.d/mirrorlist.reflector
else
    echo "WARNING: reflector failed; using a static regional mirrorlist."
    cat <<MIRRORS > /etc/pacman.d/mirrorlist
$NEPAL_MIRROR
Server = https://mirror.xeonbd.com/archlinux/\$repo/os/\$arch
Server = https://mirror.limda.net/archlinux/\$repo/os/\$arch
Server = https://in.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://mirror.sahil.world/archlinux/\$repo/os/\$arch
Server = https://mirror.4v1.in/archlinux/\$repo/os/\$arch
Server = https://mirror.sg.cdn-perfprod.com/archlinux/\$repo/os/\$arch
MIRRORS
fi
echo "Mirrors in use:"; grep ^Server /etc/pacman.d/mirrorlist | head -5

# Fetch several packages at once on the live ISO too (pacstrap uses the
# host pacman.conf for downloads).
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

# ============================================================
# BASE ARCH
# ============================================================
pacman -Syy --noconfirm archlinux-keyring

pacstrap /mnt --noconfirm --needed \
base base-devel \
linux linux-headers \
linux-firmware \
networkmanager vim git curl \
intel-ucode \
mesa vulkan-intel intel-media-driver \
dkms \
zram-generator \
power-profiles-daemon \
bluez bluez-utils \
ntfs-3g \
pipewire wireplumber pipewire-alsa pipewire-pulse

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
NTFS_UUID=""
if [[ -n "$NTFS_DRIVE" ]]; then
    NTFS_UUID=$(blkid -s UUID -o value "$NTFS_DRIVE")
fi
VIRT=$(systemd-detect-virt) || true
# The NVIDIA driver is bare-metal only; a VM gets no nvidia-drm.modeset=1 either.
if [[ -n "$VIRT" && "$VIRT" != "none" ]]; then
    NVIDIA_KARGS=""
else
    NVIDIA_KARGS=" nvidia-drm.modeset=1"
fi

# ============================================================
# CHROOT SCRIPT
# ============================================================
cat <<EOF > /mnt/next.sh
#!/usr/bin/env bash
set -e

# ============================================================
# PACKAGE INSTALL HELPER
# ============================================================
# Arch drops packages from the official repos to the AUR over time
# (e.g. lib32-giflib, lib32-openal, lib32-v4l-utils). A plain pacman -S
# then errors on the unknown package and set -e kills the whole install.
# pkg_install skips repo-missing packages and defers them to yay later.
# Packages that fail to install (pacman or AUR) end up in FAILED_PKGS,
# written to ~/failed-packages.txt at the end.
MISSING_PKGS=()
FAILED_PKGS=()
pkg_install() {
    local available=() pkg
    for pkg in "\$@"; do
        if pacman -Si "\$pkg" &>/dev/null; then
            available+=("\$pkg")
        else
            echo "WARNING: \$pkg not in official repos (moved to AUR?), deferring to yay"
            MISSING_PKGS+=("\$pkg")
        fi
    done
    if (( \${#available[@]} )); then
        pacman -S --noconfirm --needed "\${available[@]}" || {
            echo "WARNING: batch pacman install failed, retrying one at a time"
            for pkg in "\${available[@]}"; do
                pacman -S --noconfirm --needed "\$pkg" || {
                    echo "WARNING: pacman failed to install \$pkg, continuing"
                    FAILED_PKGS+=("\$pkg")
                }
            done
        }
    fi
}

# ============================================================
# AUR INSTALL HELPER
# ============================================================
# yay exits nonzero when any build fails ("Manual intervention is required"),
# which would kill the install under set -e. Install one package at a time
# and collect failures into FAILED_PKGS instead of aborting.
aur_install() {
    local pkg
    for pkg in "\$@"; do
        sudo -u "$USER" yay -S --noconfirm --needed "\$pkg" || {
            echo "WARNING: AUR build failed for \$pkg, continuing"
            FAILED_PKGS+=("\$pkg")
        }
    done
}

# ============================================================
# LAUNCHER HIDE HELPER
# ============================================================
# Hides system .desktop entries from the app launcher with NoDisplay=true
# overrides in the user's ~/.local/share/applications (copies of the system
# files, so the entries still resolve for MIME handling). The key goes in as
# the last key of [Desktop Entry], right before any Actions= line: some
# entries end with [Desktop Action] sections (an appended key would land in
# the wrong section) and some carry an explicit NoDisplay=false that would
# override an earlier NoDisplay=true (GKeyFile takes the last occurrence).
# An entry whose package isn't installed yet (blueman, file-roller, uwsm, ...
# come with hyprland.sh) gets a placeholder instead: a user-level file with
# the same id masks the system entry the moment it appears, and Hidden=true
# ("deleted at this level") needs no Exec. hyprland.sh swaps the placeholders
# for real NoDisplay copies once the packages are in.
USER_APPS=/home/$USER/.local/share/applications
hide_desktop_entry() {
    local name src dest
    mkdir -p "\$USER_APPS"
    for name in "\$@"; do
        src="/usr/share/applications/\$name"
        dest="\$USER_APPS/\$name"
        if [[ -f "\$src" ]]; then
            cp "\$src" "\$dest"
            if grep -q '^Actions=' "\$dest"; then
                sed -i -e '/^Actions=/i # hidden by archlinux.sh' -e '/^Actions=/i NoDisplay=true' "\$dest"
            else
                printf '%s\nNoDisplay=true\n' '# hidden by archlinux.sh' >> "\$dest"
            fi
            echo "hidden from launcher: \$name"
        else
            printf '%s\n[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' \
                '# placeholder by archlinux.sh: hides this entry once its package is installed' \
                "\${name%.desktop}" > "\$dest"
            echo "hidden from launcher (placeholder, not installed yet): \$name"
        fi
    done
    chown -R $USER:$USER /home/$USER/.local
}

# ============================================================
# USER
# ============================================================
useradd -m "$USER"
usermod -c "$NAME" "$USER"
usermod -aG wheel,video,audio,storage,power "$USER"
echo "$USER:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
sed -i 's/^%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# ============================================================
# LOCALE / TIME
# ============================================================
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Asia/Kathmandu /etc/localtime
hwclock --systohc

# ============================================================
# HOSTNAME
# ============================================================
echo "archlinux" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 archlinux.localdomain archlinux
HOSTS

# ============================================================
# VIRTUALBOX DETECTION
# ============================================================
if [[ "$VIRT" == "oracle" || "$VIRT" == "virtualbox" ]]; then
    echo "VirtualBox detected. Installing guest utilities..."
    pacman -S --noconfirm --needed virtualbox-guest-utils
    usermod -aG vboxsf "$USER"
    systemctl enable vboxservice.service
fi

# ============================================================
# ZRAM
# ============================================================
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

# ============================================================
# AUDIO POWER SAVE (idle codecs suspend; also needed for dGPU D3cold)
# ============================================================
cat <<'SNDPM' > /etc/modprobe.d/audio-powersave.conf
options snd_hda_intel power_save=1 power_save_controller=Y
SNDPM

# ============================================================
# MULTILIB
# ============================================================
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
pacman -Syy --noconfirm

# ============================================================
# BOOTLOADER
# ============================================================
# Installed EARLY so the system is always bootable, even if a later
# (network/AUR) step fails under set -e.
bootctl install --esp-path=/boot

cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 0
console-mode keep
editor no
LOADER

cat <<ENTRY > /boot/loader/entries/arch.conf
title   ArchLinux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 i915.fastboot=1 nowatchdog 8250.nr_uarts=0 mitigations=off$NVIDIA_KARGS
ENTRY

# ============================================================
# MKINITCPIO (early KMS = flicker-free boot)
# ============================================================
sed -i 's/^MODULES=.*/MODULES=(i915)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf block filesystems keyboard)/' /etc/mkinitcpio.conf
sed -i 's/^#\?COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^#\?COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-3)/' /etc/mkinitcpio.conf

# ============================================================
# NVIDIA (bare metal only)
# ============================================================
# A VM has no NVIDIA dGPU: the driver, its power management and the early-KMS
# modules are skipped there (the outer script also leaves nvidia-drm.modeset=1
# off the kernel command line).
if [[ -n "$VIRT" && "$VIRT" != "none" ]]; then
    echo "Running in a $VIRT VM, skipping the NVIDIA driver."
else
    pacman -S --noconfirm --needed \
        nvidia-open-dkms \
        nvidia-utils \
        lib32-nvidia-utils \
        nvidia-settings \
        nvidia-prime \
        libva-nvidia-driver \
        opencl-nvidia

    # Runtime power management
    cat <<'NVPM' > /etc/modprobe.d/nvidia-pm.conf
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_EnableS0ixPowerManagement=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
NVPM

    systemctl enable nvidia-suspend.service nvidia-resume.service || true

    # Runtime D3 (kernel-side runtime PM so the dGPU powers off).
    # add|bind: driver binds inside the initramfs (early KMS), where this rule
    # isn't present -- matching "add" applies it on the udev coldplug replay.
    cat <<'NVUDEV' > /etc/udev/rules.d/80-nvidia-pm.rules
# Enable runtime PM for the NVIDIA GPU and its HDMI audio function
ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", TEST=="power/control", ATTR{power/control}="auto"

# Revert to always-on when the driver unbinds
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", TEST=="power/control", ATTR{power/control}="on"
NVUDEV

    # Early KMS for the dGPU too, and rebuild its module in the initramfs
    # whenever the driver or the kernel changes.
    sed -i 's/^MODULES=.*/MODULES=(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf

    mkdir -p /etc/pacman.d/hooks
    cat <<'NVHOOK' > /etc/pacman.d/hooks/nvidia.hook
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia-open-dkms
Target=linux

[Action]
Description=Update NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
NVHOOK
fi

# Rebuild the initramfs with the early-KMS modules and the hook/compression
# changes above (pacstrap built it with the stock config).
mkinitcpio -P

# ============================================================
# PLYMOUTH BOOT SPLASH (optional)
# ============================================================
# The default theme (bgrt on Arch: spinner under the firmware's OEM logo;
# plain spinner without BGRT) is cloned to <theme>-nologo WITHOUT
# watermark.png, the distro logo drawn below the spinner. Cloning instead of
# deleting the file from the package's own theme means a plymouth upgrade
# can't bring the logo back. bgrt has no images of its own (its ImageDir
# points at spinner), so the clone is built from whatever ImageDir the theme
# uses. The clone also gets a bigger, lower spinner: the throbber-*.png
# frames are redrawn as vectors at SPINNER_SIZE px (the two-step plugin has
# no scale key, and upscaling the 32 px originals looks blurry) and
# VerticalAlignment is set to SPINNER_VALIGN. Splash on boot only: the
# poweroff/reboot/halt/kexec units are masked so shutdown goes straight to
# the quiet, cursor-less console.
if [[ "$INSTALL_PLYMOUTH" =~ ^[Nn] ]]; then
    echo "Skipping Plymouth."
else
    # librsvg provides rsvg-convert, which renders the spinner frames.
    pkg_install plymouth librsvg

    # Upstream frames are 32 px at VerticalAlignment=.7 (0 = top, 1 = bottom).
    SPINNER_SIZE=48
    SPINNER_VALIGN=.76
    SPINNER_FRAMES=30   # same count as upstream, so the rotation speed is unchanged

    # One frame of the GNOME/Adwaita spinner as SVG on stdout (frame 1..SPINNER_FRAMES).
    # Geometry measured from the upstream 32 px frames: a 4-unit ring of
    # radius 9.5 on a 32-unit canvas, the track in #7c7c7c at 24 % opacity,
    # and a white 96 degree arc with round caps that advances
    # 360/SPINNER_FRAMES degrees per frame (clockwise, starting near 3 o'clock).
    spinner_frame_svg() {
        awk -v n="\$1" -v frames="\$SPINNER_FRAMES" 'BEGIN {
            pi = atan2(0, -1); r = 9.5; sweep = 96
            start = -6 + (n - 1) * 360 / frames
            a0 = start * pi / 180; a1 = (start + sweep) * pi / 180
            printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\">\n"
            printf "<circle cx=\"16\" cy=\"16\" r=\"%s\" fill=\"none\" stroke=\"#7c7c7c\" stroke-opacity=\"0.243\" stroke-width=\"4\"/>\n", r
            printf "<path d=\"M %.4f %.4f A %s %s 0 0 1 %.4f %.4f\" fill=\"none\" stroke=\"#ffffff\" stroke-width=\"4\" stroke-linecap=\"round\"/>\n", 16 + r * cos(a0), 16 + r * sin(a0), r, r, 16 + r * cos(a1), 16 + r * sin(a1)
            printf "</svg>\n"
        }'
    }

    # plymouth hook right after systemd, and 'splash' on the kernel command line.
    sed -i 's/^HOOKS=(systemd /HOOKS=(systemd plymouth /' /etc/mkinitcpio.conf
    sed -i '/^options /s/\$/ splash/' /boot/loader/entries/arch.conf

    THEME=\$(plymouth-set-default-theme 2>/dev/null || true)
    THEME=\${THEME%-nologo}
    THEME=\${THEME:-spinner}
    SRC_DIR=/usr/share/plymouth/themes/\$THEME
    SRC_CONF=\$SRC_DIR/\$THEME.plymouth
    IMAGE_DIR=\$(sed -nE 's/^ImageDir=//p' "\$SRC_CONF" | head -n1)
    IMAGE_DIR=\${IMAGE_DIR:-\$SRC_DIR}
    DST=/usr/share/plymouth/themes/\$THEME-nologo

    echo "Building theme \$THEME-nologo (\$THEME without watermark.png)"
    rm -rf "\$DST"
    mkdir -p "\$DST"
    cp -r "\$IMAGE_DIR"/. "\$DST/"
    rm -f "\$DST"/*.plymouth "\$DST/watermark.png"
    sed -E \
        -e 's/^(Name=.*)/\1 (no logo)/' \
        -e "s|^ImageDir=.*|ImageDir=\$DST|" \
        -e "s|^ScriptFile=\$SRC_DIR/|ScriptFile=\$DST/|" \
        -e "s|^VerticalAlignment=.*|VerticalAlignment=\$SPINNER_VALIGN|" \
        "\$SRC_CONF" > "\$DST/\$THEME-nologo.plymouth"
    grep -q '^ImageDir=' "\$DST/\$THEME-nologo.plymouth" \
        || sed -i "/^\[two-step\]/a ImageDir=\$DST" "\$DST/\$THEME-nologo.plymouth"
    grep -q '^VerticalAlignment=' "\$DST/\$THEME-nologo.plymouth" \
        || sed -i "/^\[two-step\]/a VerticalAlignment=\$SPINNER_VALIGN" "\$DST/\$THEME-nologo.plymouth"

    # Bigger spinner: replace the clone's throbber-*.png with frames rendered
    # from vector art at SPINNER_SIZE (the package's own frames stay untouched).
    if compgen -G "\$DST/throbber-*.png" >/dev/null; then
        echo "Rendering \$SPINNER_FRAMES spinner frames at \${SPINNER_SIZE}px"
        TMP=\$(mktemp -d)
        for ((i = 1; i <= SPINNER_FRAMES; i++)); do
            FRAME=\$(printf 'throbber-%04d' "\$i")
            spinner_frame_svg "\$i" > "\$TMP/\$FRAME.svg"
            rsvg-convert -w "\$SPINNER_SIZE" -h "\$SPINNER_SIZE" "\$TMP/\$FRAME.svg" -o "\$TMP/\$FRAME.png"
        done
        rm -f "\$DST"/throbber-*.png
        cp "\$TMP"/throbber-*.png "\$DST/"
        rm -rf "\$TMP"
    else
        echo "theme has no throbber-*.png frames, spinner size left as is"
    fi

    # Set the clone as default and rebuild the initramfs with the hook.
    plymouth-set-default-theme -R "\$THEME-nologo"

    # Splash at boot only.
    systemctl mask plymouth-poweroff.service plymouth-reboot.service plymouth-halt.service plymouth-kexec.service
fi

# ============================================================
# AUR (yay)
# ============================================================
cd /tmp
sudo -u "$USER" git clone --depth 1 https://aur.archlinux.org/yay.git
cd yay
sudo -u "$USER" makepkg -sri --needed --noconfirm
cd /
rm -rf /tmp/yay

# ============================================================
# NTFS ROOT PASSWORD FIX
# ============================================================
cat <<'POLKIT' > /etc/polkit-1/rules.d/49-nopasswd_global.rules
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT

chmod 644 /etc/polkit-1/rules.d/49-nopasswd_global.rules

if [[ -n "$NTFS_DRIVE" ]]; then
    mkdir -p /mnt/HOME
    echo "UUID=$NTFS_UUID /mnt/HOME auto nosuid,nodev,nofail,x-gvfs-show 0 0" >> /etc/fstab
    mount -a
else
    echo "No separate NTFS drive specified, skipping..."
fi

# ============================================================
# BATTERY CHARGE THRESHOLD
# ============================================================
cat <<'BATTERY' > /etc/systemd/system/battery-charge-threshold.service
[Unit]
Description=Set battery charge threshold
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
StartLimitBurst=0

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'echo 80 | tee /sys/class/power_supply/BAT*/charge_control_end_threshold > /dev/null'

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
BATTERY

# ============================================================
# ZSH / STARSHIP
# ============================================================
pacman -S --noconfirm --needed \
zsh \
zsh-syntax-highlighting \
zsh-autosuggestions \
starship

# Set zsh as default shell for user
chsh -s /bin/zsh "$USER"

cat <<'ZSHRC' > /home/$USER/.zshrc
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

HISTFILE=~/.history
HISTSIZE=10000
SAVEHIST=50000

setopt inc_append_history

PROMPT_EOL_MARK=''

eval "\$(starship init zsh)"

export PATH="\$PATH:\$HOME/.local/bin"
ZSHRC

chown $USER:$USER /home/$USER/.zshrc

# ============================================================
# WINE / GAMING STACK (optional)
# ============================================================
# lib32-giflib / lib32-openal / lib32-v4l-utils were dropped from multilib
# (wine >=10 is WoW64: 32-bit Windows apps use 64-bit libs). Their AUR
# builds are broken/pointless -- do not re-add them.
if [[ "$INSTALL_GAMING" =~ ^[Nn] ]]; then
    echo "Skipping the gaming stack."
else
    pkg_install \
        wine-staging wine-mono wine-gecko \
        giflib \
        libpng lib32-libpng \
        libldap lib32-libldap \
        gnutls lib32-gnutls \
        mpg123 lib32-mpg123 \
        openal \
        v4l-utils \
        libpulse lib32-libpulse \
        libgpg-error lib32-libgpg-error \
        libgcrypt lib32-libgcrypt \
        alsa-plugins lib32-alsa-plugins \
        alsa-lib lib32-alsa-lib \
        libjpeg-turbo lib32-libjpeg-turbo \
        sqlite lib32-sqlite \
        libxcomposite lib32-libxcomposite \
        libxinerama lib32-libxinerama \
        ncurses lib32-ncurses \
        ocl-icd lib32-ocl-icd \
        libxslt lib32-libxslt \
        libva lib32-libva \
        gtk3 lib32-gtk3 \
        gst-plugins-base-libs \
        gst-libav \
        vulkan-intel lib32-vulkan-intel \
        lib32-mesa \
        gst-plugins-good \
        python-protobuf \
        lutris
fi

# ============================================================
# FONTS
# ============================================================
pkg_install \
    noto-fonts \
    noto-fonts-emoji \
    noto-fonts-extra \
    ttf-liberation \
    noto-fonts-cjk \
    ttf-dejavu \
    otf-font-awesome \
    ttf-fira-sans \
    ttf-jetbrains-mono

# ============================================================
# PROGRAMS
# ============================================================
pkg_install \
    vlc vlc-plugins-all \
    obs-studio \
    qbittorrent \
    gvfs-mtp \
    ffmpegthumbnailer \
    xdg-user-dirs \
    wget

# ============================================================
# KDE PLASMA DESKTOP (optional)
# ============================================================
# plasma-desktop instead of the full plasma group: just the shell plus the
# applets a laptop needs (audio, network, bluetooth, power, displays), SDDM
# with its System Settings module, and a small set of apps. Fonts: Fira Sans
# (installed above) for the UI, JetBrains Mono for monospace, applied to
# Plasma/Qt via kdeglobals, to GTK apps via settings.ini (kde-gtk-config
# keeps them in sync afterwards) and to the SDDM greeter.
if [[ "$INSTALL_KDE" =~ ^[Nn] ]]; then
    echo "Skipping KDE Plasma."
else
    # Explicit providers (phonon backend, Qt multimedia backend) so pacman
    # doesn't have to pick one itself under --noconfirm.
    pkg_install \
        plasma-desktop \
        plasma-pa plasma-nm bluedevil powerdevil kscreen \
        plasma-systemmonitor \
        sddm sddm-kcm \
        kde-gtk-config breeze-gtk xdg-desktop-portal-kde \
        phonon-qt6-vlc qt6-multimedia-ffmpeg \
        dolphin kio-extras ffmpegthumbs kdegraphics-thumbnailers \
        konsole ark gwenview okular kwrite spectacle

    systemctl enable sddm.service

    # SDDM: Breeze theme and the UI font (what sddm-kcm's "Apply Plasma
    # Settings" would write).
    mkdir -p /etc/sddm.conf.d
    cat <<'SDDMCONF' > /etc/sddm.conf.d/kde_settings.conf
[Theme]
Current=breeze
CursorTheme=breeze_cursors
Font=Fira Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
SDDMCONF

    # Plasma/Qt fonts.
    mkdir -p /home/$USER/.config/gtk-3.0 /home/$USER/.config/gtk-4.0
    cat <<'KDEGLOBALS' > /home/$USER/.config/kdeglobals
[General]
font=Fira Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
menuFont=Fira Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
toolBarFont=Fira Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
smallestReadableFont=Fira Sans,8,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
fixed=JetBrains Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1

[WM]
activeFont=Fira Sans,10,-1,5,700,0,0,0,0,0,0,0,0,0,0,1
KDEGLOBALS

    # GTK apps (Chrome, Lutris, ...) until kde-gtk-config takes over.
    cat <<'GTK3' > /home/$USER/.config/gtk-3.0/settings.ini
[Settings]
gtk-font-name=Fira Sans 10
gtk-theme-name=Breeze
gtk-icon-theme-name=breeze
gtk-cursor-theme-name=breeze_cursors
GTK3
    cat <<'GTK4' > /home/$USER/.config/gtk-4.0/settings.ini
[Settings]
gtk-font-name=Fira Sans 10
gtk-icon-theme-name=breeze
gtk-cursor-theme-name=breeze_cursors
GTK4

    # KWallet off: otherwise Chrome (and any Chromium browser) picks it as
    # its password store and kwalletd pops a "create wallet" dialog on every
    # launch. Browsers fall back to their basic store; plasma-nm saves Wi-Fi
    # passwords as system connections instead.
    cat <<'KWALLET' > /home/$USER/.config/kwalletrc
[Wallet]
Enabled=false
KWALLET

    # No Plasma login splash (the Breeze logo animation between SDDM and the
    # desktop); Plymouth already covers boot, so go straight to the desktop.
    cat <<'KSPLASH' > /home/$USER/.config/ksplashrc
[KSplash]
Engine=none
Theme=None
KSPLASH
    chown -R $USER:$USER /home/$USER/.config
fi

# ============================================================
# DEVELOPMENT STACK (optional)
# ============================================================
if [[ "$INSTALL_DEV" =~ ^[Nn] ]]; then
    echo "Skipping the development stack."
else
    pkg_install \
        nodejs-lts-krypton \
        npm \
        jdk25-openjdk \
        docker \
        docker-buildx \
        docker-compose

    usermod -aG docker $USER

    sudo -u "$USER" npm install -g @angular/cli --prefix=/home/$USER/.local

    aur_install postman-bin

    systemctl enable docker.service
fi

# ============================================================
# LIBREOFFICE (optional)
# ============================================================
# Only Writer, Calc and Impress stay in the launcher; Start Center, Base,
# Draw, Math and the XSLT filter dialog are hidden.
if [[ "$INSTALL_OFFICE" =~ ^[Nn] ]]; then
    echo "Skipping LibreOffice."
else
    pkg_install libreoffice-fresh

    for src in /usr/share/applications/libreoffice-*.desktop; do
        [[ -f "\$src" ]] || continue
        case "\$(basename "\$src")" in
            libreoffice-writer.desktop|libreoffice-calc.desktop|libreoffice-impress.desktop) ;;
            *) hide_desktop_entry "\$(basename "\$src")" ;;
        esac
    done
fi

# ============================================================
# VIRTUALBOX HOST (optional)
# ============================================================
# Arch dropped the prebuilt virtualbox-host-modules-arch package, so the
# vboxdrv/vboxnetadp/vboxnetflt modules come from dkms (linux-headers is in
# the base install, the same mechanism nvidia-open-dkms relies on) and
# pacman's dkms hook rebuilds them on every kernel upgrade. The package's
# modules-load.d file loads them at boot. virtualbox-guest-iso puts
# VBoxGuestAdditions.iso where VirtualBox looks for it, so "Insert Guest
# Additions CD image" works offline. vboxusers is needed for USB passthrough.
if [[ "$INSTALL_VBOX" =~ ^[Nn] ]]; then
    echo "Skipping VirtualBox."
else
    if [[ -n "$VIRT" && "$VIRT" != "none" ]]; then
        echo "note: this looks like a $VIRT guest; VirtualBox as a nested hypervisor only works with nested VT-x/AMD-V enabled on the outer VM"
    fi
    pkg_install virtualbox virtualbox-host-dkms virtualbox-guest-iso

    if getent group vboxusers >/dev/null; then
        usermod -aG vboxusers "$USER"
    fi

fi

# ============================================================
# GIT GLOBAL CONFIG
# ============================================================
sudo -u "$USER" git config --global user.name "sandipsky"
sudo -u "$USER" git config --global user.email "sandipshakya75@gmail.com"
sudo -u "$USER" git config --global core.pager cat
# Pushing over HTTPS needs a credential helper: with current curl, git drops
# a token embedded in the clone URL after the first request of a push and
# falls back to the helper. Clone as https://sandipsky:<token>@github.com/...
# and the first push saves the token to ~/.git-credentials with no prompt;
# a bare https://<token>@ URL isn't saved, so that push would ask instead.
sudo -u "$USER" git config --global credential.helper store

# ============================================================
# HOME FOLDERS
# ============================================================
# The standard XDG user dirs (Documents, Downloads, Music, ...) plus
# ~/Projects as an extra one: xdg-user-dirs-update only creates the standard
# eight, but keeps local additions to user-dirs.dirs on its later runs, so the
# XDG_PROJECTS_DIR line survives. The GTK bookmarks file gives Nautilus and
# the GTK file chooser their sidebar folders; outside GNOME nothing seeds it
# (xdg-user-dirs-gtk's autostart is OnlyShowIn=GNOME), so write it here.
# Append-if-missing, so bookmarks added later are kept.
sudo -u "$USER" -H xdg-user-dirs-update
USER_DIRS=/home/$USER/.config/user-dirs.dirs
grep -q '^XDG_PROJECTS_DIR=' "\$USER_DIRS" 2>/dev/null \
    || echo 'XDG_PROJECTS_DIR="\$HOME/Projects"' >> "\$USER_DIRS"
BOOKMARKS=/home/$USER/.config/gtk-3.0/bookmarks
mkdir -p "\$(dirname "\$BOOKMARKS")"
touch "\$BOOKMARKS"
for dir in Documents Downloads Music Pictures Videos Projects; do
    mkdir -p "/home/$USER/\$dir"
    grep -qxF "file:///home/$USER/\$dir" "\$BOOKMARKS" || echo "file:///home/$USER/\$dir" >> "\$BOOKMARKS"
done
chown -R $USER:$USER /home/$USER

# ============================================================
# AUR APPS
# ============================================================
aur_install google-chrome visual-studio-code-bin

# ============================================================
# SPOTIFY (+ adblock)
# ============================================================
# Both come from the AUR: spotify repackages the official .deb, and
# spotify-adblock-git builds abba23/spotify-adblock into
# /usr/lib/spotify-adblock.so (config in /etc/spotify-adblock/config.toml).
# makepkg verifies the Spotify repo signature, so the signing key has to be
# in the build user's keyring first. Best-effort: aur_install continues on
# failure (did Spotify rotate its signing key? Compare the validpgpkeys line
# in https://aur.archlinux.org/packages/spotify). A stale pubring lock from
# an interrupted gpg run would make the import hang, so clear it first.
rm -f /home/$USER/.gnupg/public-keys.d/pubring.db.lock
sudo -u "$USER" -H bash -c 'curl -sS https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.gpg | gpg --import -' \
    || echo "WARNING: could not import the Spotify signing key, the spotify build will fail"
aur_install spotify spotify-adblock-git

# One launcher entry with the adblocker preloaded: override spotify.desktop in
# /usr/local/share/applications (outranks /usr/share) and hide the extra
# "Spotify (adblock)" entry the AUR package ships.
if [[ -f /usr/share/applications/spotify.desktop && -f /usr/lib/spotify-adblock.so ]]; then
    mkdir -p /usr/local/share/applications
    cp /usr/share/applications/spotify.desktop /usr/local/share/applications/spotify.desktop
    sed -i 's|^Exec=|Exec=env LD_PRELOAD=/usr/lib/spotify-adblock.so |' /usr/local/share/applications/spotify.desktop
    hide_desktop_entry spotify-adblock.desktop
fi

# ============================================================
# REPO-DROPPED PACKAGES (AUR fallback)
# ============================================================
if (( \${#MISSING_PKGS[@]} )); then
    echo "Installing packages that moved to AUR: \${MISSING_PKGS[*]}"
    aur_install "\${MISSING_PKGS[@]}"
fi

# ============================================================
# LAUNCHER CLEANUP
# ============================================================
# Developer tools and utilities that arrive as dependencies and clutter the
# app grid. Runs after every install step so it catches an entry no matter
# which package pulled it in; entries not installed yet (the Qt developer
# tools from qt6-tools, and blueman, file-roller, uwsm's uuctl, avahi, ...
# that hyprland.sh brings in) get a placeholder, see hide_desktop_entry.
hide_desktop_entry \
    org.kde.plasma.emojier.desktop org.kde.kmenuedit.desktop \
    vim.desktop \
    lstopo.desktop cmake-gui.desktop \
    qv4l2.desktop qvidcap.desktop \
    assistant.desktop designer.desktop linguist.desktop qdbusviewer.desktop \
    java-java25-openjdk.desktop jconsole-java25-openjdk.desktop jshell-java25-openjdk.desktop \
    avahi-discover.desktop bssh.desktop bvnc.desktop \
    xgps.desktop xgpsspeed.desktop \
    remote-viewer.desktop \
    org.freedesktop.IBus.Setup.desktop \
    blueman-adapters.desktop blueman-manager.desktop \
    org.gnome.FileRoller.desktop \
    uuctl.desktop

# ============================================================
# DNS - Cloudflare via systemd-resolved
# ============================================================
# Some routers hand out dead DNS servers via DHCP; glibc tries nameservers in
# order with a 5 s timeout, so with no local cache every lookup stalls.
# A global systemd-resolved config with Domains=~. outranks whatever DNS any
# network's DHCP hands out, and resolved is a local cache that also skips
# unresponsive servers. Trade-off: LAN hostnames only the router can resolve
# won't resolve (mDNS/.local via Avahi is unaffected). /etc/resolv.conf is
# pointed at resolved's stub after the chroot: arch-chroot bind-mounts the
# live ISO's resolv.conf over it in here, so it can't be replaced yet.
mkdir -p /etc/systemd/resolved.conf.d
cat <<'DNSCONF' > /etc/systemd/resolved.conf.d/10-global-dns.conf
# Prefer these resolvers on every network (Domains=~. outranks per-link
# DHCP-provided DNS), so dead router DNS servers are never consulted.
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
Domains=~.
DNSCONF
systemctl enable systemd-resolved.service

# ============================================================
# SERVICES
# ============================================================
systemctl enable NetworkManager bluetooth power-profiles-daemon fstrim.timer
systemctl enable battery-charge-threshold.service
systemctl --global enable pipewire pipewire-pulse wireplumber

systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service

# ============================================================
# FAILED PACKAGE REPORT
# ============================================================
if (( \${#FAILED_PKGS[@]} )); then
    printf '%s\n' "\${FAILED_PKGS[@]}" > /home/$USER/failed-packages.txt
    chown $USER:$USER /home/$USER/failed-packages.txt
    echo "WARNING: these packages failed to install (saved to ~/failed-packages.txt):"
    printf '  %s\n' "\${FAILED_PKGS[@]}"
    echo 'Retry after reboot with: yay -S --needed \$(cat ~/failed-packages.txt)'
fi

echo "INSTALLATION COMPLETE"
EOF

# ============================================================
# RUN CHROOT SCRIPT
# ============================================================
chmod +x /mnt/next.sh
arch-chroot /mnt /next.sh
rm /mnt/next.sh

# ============================================================
# DNS STUB RESOLVER (post-chroot)
# ============================================================
# Every app, including browsers that read resolv.conf directly (Chromium),
# goes through resolved's cache. Done out here because arch-chroot
# bind-mounts the live ISO's /etc/resolv.conf into the chroot.
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

# ============================================================
# DONE
# ============================================================
echo "DONE. You can reboot now."
