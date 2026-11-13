#!/usr/bin/env bash
# Fresh Arch Linux install (systemd-boot, Intel + NVIDIA laptop); a VM skips
# the laptop hardware pieces. Leaves wheel with passwordless sudo so that
# hyprland.sh can run unattended; it reverts that at its end. If hyprland.sh
# is never run:
#   sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
set -e

# ============================================================
# VM DETECTION
# ============================================================
# "none" on bare metal; a VM skips every laptop hardware piece (microcode,
# firmware, GPU drivers, dkms, power tweaks) and the NTFS/VirtualBox prompts.
VIRT=$(systemd-detect-virt --vm 2>/dev/null) || VIRT=none
if [[ "$VIRT" != none ]]; then
    echo "Running in a $VIRT VM: skipping the laptop hardware pieces."
fi

# ============================================================
# PROMPTS
# ============================================================
read -p "EFI partition (e.g. /dev/nvme0n1p1): " EFI
read -p "ROOT partition (e.g. /dev/nvme0n1p2): " ROOT
NTFS_DRIVE=""
if [[ "$VIRT" == none ]]; then
    read -p "Enter NTFS D Drive partition (optional, e.g. /dev/nvme1n1p1, blank to skip): " NTFS_DRIVE
fi
read -p "Username: " NEW_USER
read -p "Full Name: " NAME
# Also root's password. Set after the chroot (see PASSWORDS), never pasted
# into the generated chroot script.
while :; do
    read -s -p "Password: " PASSWORD; echo
    read -s -p "Repeat password: " PASSWORD2; echo
    [[ -n "$PASSWORD" && "$PASSWORD" == "$PASSWORD2" ]] && break
    echo "Passwords don't match or are empty, try again."
done
read -p "Install the development stack (node, JDK, Angular CLI, Docker, Postman)? [Y/n]: " INSTALL_DEV
read -p "Install the gaming stack (wine-staging, lutris)? [Y/n]: " INSTALL_GAMING
read -p "Install LibreOffice (only Writer, Calc, Impress in the launcher)? [Y/n]: " INSTALL_OFFICE
read -p "Install the Plymouth boot splash (default theme, no distro logo)? [Y/n]: " INSTALL_PLYMOUTH
if [[ "$VIRT" == none ]]; then
    read -p "Install VirtualBox (VM host + dkms modules + guest-additions ISO)? [Y/n]: " INSTALL_VBOX
else
    INSTALL_VBOX=n
fi

# ============================================================
# FILESYSTEM
# ============================================================
# Last stop before anything is written.
for dev in "$EFI" "$ROOT" ${NTFS_DRIVE:+"$NTFS_DRIVE"}; do
    if [[ ! -b "$dev" ]]; then
        echo "ERROR: $dev is not a block device." >&2
        exit 1
    fi
done
echo "About to FORMAT $EFI (FAT32) and $ROOT (ext4). Everything on them will be lost."
read -p "Type yes to continue: " CONFIRM
[[ "$CONFIRM" == yes ]] || { echo "Aborted, nothing was written."; exit 1; }

mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

mount -o noatime "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# ============================================================
# MIRRORS
# ============================================================
# Rank nearby HTTPS mirrors by download rate, Nepali mirror pinned first;
# pacstrap copies the mirrorlist into the installed system.
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

# pacstrap downloads with the host pacman.conf.
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

# ============================================================
# BASE ARCH
# ============================================================
pacman -Syy --noconfirm archlinux-keyring

# Bare metal only: microcode, firmware, Intel GPU drivers, headers + dkms.
HW_PKGS=()
if [[ "$VIRT" == none ]]; then
    HW_PKGS=(linux-headers linux-firmware intel-ucode vulkan-intel intel-media-driver dkms)
fi

pacstrap /mnt --noconfirm --needed \
base base-devel \
linux \
networkmanager vim git curl \
mesa \
zram-generator \
power-profiles-daemon \
bluez bluez-utils \
ntfs-3g \
pipewire wireplumber pipewire-alsa pipewire-pulse \
"${HW_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
NTFS_UUID=""
if [[ -n "$NTFS_DRIVE" ]]; then
    NTFS_UUID=$(blkid -s UUID -o value "$NTFS_DRIVE")
fi
# Laptop-only boot entry pieces: the microcode initrd (intel-ucode isn't
# installed in a VM), i915.fastboot (no modeset flicker), nvidia-drm.modeset.
if [[ "$VIRT" == none ]]; then
    INITRDS=$'initrd  /intel-ucode.img\ninitrd  /initramfs-linux.img'
    HW_KARGS=" i915.fastboot=1 nvidia-drm.modeset=1"
else
    INITRDS='initrd  /initramfs-linux.img'
    HW_KARGS=""
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
# Packages that moved from the repos to the AUR would fail pacman -S under
# set -e: skip and defer them to yay. Every install failure lands in
# FAILED_PKGS, written to ~/failed-packages.txt at the end.
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
# One package at a time: a failed yay build must not abort the install.
aur_install() {
    local pkg
    for pkg in "\$@"; do
        sudo -u "$NEW_USER" yay -S --noconfirm --needed "\$pkg" || {
            echo "WARNING: AUR build failed for \$pkg, continuing"
            FAILED_PKGS+=("\$pkg")
        }
    done
}

# ============================================================
# LAUNCHER HIDE HELPER
# ============================================================
# NoDisplay=true copies of system .desktop entries in ~/.local/share/applications
# (copies, so MIME handling still resolves). The key goes right before any
# Actions= line: it has to stay inside [Desktop Entry] and win over a later
# NoDisplay=false. An entry whose package isn't installed yet gets a Hidden=true
# placeholder, which hyprland.sh swaps for a real copy later.
USER_APPS=/home/$NEW_USER/.local/share/applications
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
    chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.local
}

# ============================================================
# USER
# ============================================================
# Passwords and the full name are set by the outer script (see PASSWORDS):
# this file is an unquoted heredoc, so they can't be pasted in safely.
useradd -m "$NEW_USER"
usermod -aG wheel,video,audio,storage,power "$NEW_USER"
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
    usermod -aG vboxsf "$NEW_USER"
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
if [[ "$VIRT" == none ]]; then
    cat <<'SNDPM' > /etc/modprobe.d/audio-powersave.conf
options snd_hda_intel power_save=1 power_save_controller=Y
SNDPM
fi

# ============================================================
# MULTILIB
# ============================================================
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
pacman -Syy --noconfirm

# ============================================================
# BOOTLOADER
# ============================================================
# Early, so the system boots even if a later step fails.
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
$INITRDS
options root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 nowatchdog 8250.nr_uarts=0 mitigations=off$HW_KARGS
ENTRY

# Fallback entry with the full initramfs: autodetect runs against the live
# ISO's modules and can miss one. The menu is hidden; hold Space at boot.
sed -e 's/^title .*/title   ArchLinux (fallback initramfs)/' \
    -e 's|/initramfs-linux.img|/initramfs-linux-fallback.img|' \
    /boot/loader/entries/arch.conf > /boot/loader/entries/arch-fallback.conf

# ============================================================
# MKINITCPIO (early KMS = flicker-free boot)
# ============================================================
if [[ "$VIRT" == none ]]; then
    sed -i 's/^MODULES=.*/MODULES=(i915)/' /etc/mkinitcpio.conf
fi
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf block filesystems keyboard)/' /etc/mkinitcpio.conf
sed -i 's/^#\?COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^#\?COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-3)/' /etc/mkinitcpio.conf

# ============================================================
# NVIDIA (bare metal only)
# ============================================================
if [[ "$VIRT" != none ]]; then
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

    # Runtime D3. add|bind: the driver binds inside the initramfs, where this
    # rule isn't present, so "add" applies it on the udev coldplug replay.
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

    # Early KMS for the dGPU, and an initramfs rebuild whenever the driver
    # changes (no Target=linux: a kernel upgrade already triggers mkinitcpio's hook).
    sed -i 's/^MODULES=.*/MODULES=(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf

    mkdir -p /etc/pacman.d/hooks
    cat <<'NVHOOK' > /etc/pacman.d/hooks/nvidia.hook
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia-open-dkms

[Action]
Description=Update NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
NVHOOK
fi

# ============================================================
# PLYMOUTH BOOT SPLASH (optional)
# ============================================================
# The default theme is cloned to <theme>-nologo without watermark.png (the
# distro logo), so an upgrade can't bring the logo back, and gets a bigger,
# lower spinner (frames redrawn as vectors: the plugin has no scale key).
# Splash on boot only; the shutdown units are masked.
if [[ "$INSTALL_PLYMOUTH" =~ ^[Nn] ]]; then
    echo "Skipping Plymouth."
else
    # librsvg provides rsvg-convert, which renders the spinner frames.
    pkg_install plymouth librsvg

    # Upstream frames are 32 px at VerticalAlignment=.7 (0 = top, 1 = bottom).
    SPINNER_SIZE=48
    SPINNER_VALIGN=.76
    SPINNER_FRAMES=30   # same count as upstream, so the rotation speed is unchanged

    # One frame (1..SPINNER_FRAMES) of the Adwaita spinner as SVG, geometry
    # measured from the upstream 32 px frames.
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

    sed -i 's/^HOOKS=(systemd /HOOKS=(systemd plymouth /' /etc/mkinitcpio.conf
    sed -i '/^options /s/\$/ splash/' /boot/loader/entries/arch.conf /boot/loader/entries/arch-fallback.conf

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

    # No -R: the initramfs is rebuilt once, below.
    plymouth-set-default-theme "\$THEME-nologo"

    systemctl mask plymouth-poweroff.service plymouth-reboot.service plymouth-halt.service plymouth-kexec.service
fi

# ============================================================
# INITRAMFS
# ============================================================
# One rebuild for everything above.
mkinitcpio -P

# ============================================================
# AUR (yay)
# ============================================================
cd /tmp
sudo -u "$NEW_USER" git clone --depth 1 https://aur.archlinux.org/yay.git
cd yay
sudo -u "$NEW_USER" makepkg -sri --needed --noconfirm
cd /
rm -rf /tmp/yay

# ============================================================
# POLKIT: NO PASSWORD PROMPTS FOR WHEEL
# ============================================================
# Deliberately broad: single-user laptop, $NEW_USER is the only wheel member.
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
    # Not mounted here: a dirty or hibernated Windows volume would refuse the
    # mount and abort the script (nofail only covers a missing device).
else
    echo "No separate NTFS drive specified, skipping..."
fi

# ============================================================
# BATTERY CHARGE THRESHOLD
# ============================================================
# Enabled in SERVICES below.
if [[ "$VIRT" == none ]]; then
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
fi

# ============================================================
# ZSH / STARSHIP
# ============================================================
pacman -S --noconfirm --needed \
zsh \
zsh-syntax-highlighting \
zsh-autosuggestions \
starship

chsh -s /bin/zsh "$NEW_USER"

cat <<'ZSHRC' > /home/$NEW_USER/.zshrc
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

chown $NEW_USER:$NEW_USER /home/$NEW_USER/.zshrc

# ============================================================
# WINE / GAMING STACK (optional)
# ============================================================
# lib32-giflib / lib32-openal / lib32-v4l-utils were dropped from multilib
# (wine >=10 is WoW64); their AUR builds are broken, do not re-add them.
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
        lib32-mesa \
        gst-plugins-good \
        python-protobuf \
        lutris

    if [[ "$VIRT" == none ]]; then
        pkg_install vulkan-intel lib32-vulkan-intel
    fi
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

    usermod -aG docker $NEW_USER

    # Best effort: a registry outage must not abort the install.
    sudo -u "$NEW_USER" npm install -g @angular/cli --prefix=/home/$NEW_USER/.local \
        || echo "WARNING: npm install of @angular/cli failed; retry after reboot with: npm install -g @angular/cli --prefix=~/.local"

    aur_install postman-bin

    systemctl enable docker.service
fi

# ============================================================
# LIBREOFFICE (optional)
# ============================================================
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
# The host modules come from dkms (Arch dropped the prebuilt package); the
# dkms hook rebuilds them on kernel upgrades. vboxusers is for USB passthrough.
if [[ "$INSTALL_VBOX" =~ ^[Nn] ]]; then
    echo "Skipping VirtualBox."
else
    pkg_install virtualbox virtualbox-host-dkms virtualbox-guest-iso

    if getent group vboxusers >/dev/null; then
        usermod -aG vboxusers "$NEW_USER"
    fi

fi

# ============================================================
# GIT GLOBAL CONFIG
# ============================================================
sudo -u "$NEW_USER" git config --global user.name "sandipsky"
sudo -u "$NEW_USER" git config --global user.email "sandipshakya75@gmail.com"
sudo -u "$NEW_USER" git config --global core.pager cat
# Clone as https://sandipsky:<token>@github.com/... and the first push saves
# the token to ~/.git-credentials; a bare https://<token>@ URL isn't saved.
sudo -u "$NEW_USER" git config --global credential.helper store

# ============================================================
# HOME FOLDERS
# ============================================================
# ~/Projects on top of the standard XDG dirs (xdg-user-dirs-update keeps the
# extra line on later runs). Nothing seeds the GTK sidebar bookmarks outside
# GNOME, so they are written here, append-if-missing.
sudo -u "$NEW_USER" -H xdg-user-dirs-update
USER_DIRS=/home/$NEW_USER/.config/user-dirs.dirs
grep -q '^XDG_PROJECTS_DIR=' "\$USER_DIRS" 2>/dev/null \
    || echo 'XDG_PROJECTS_DIR="\$HOME/Projects"' >> "\$USER_DIRS"
BOOKMARKS=/home/$NEW_USER/.config/gtk-3.0/bookmarks
mkdir -p "\$(dirname "\$BOOKMARKS")"
touch "\$BOOKMARKS"
for dir in Documents Downloads Music Pictures Videos Projects; do
    mkdir -p "/home/$NEW_USER/\$dir"
    grep -qxF "file:///home/$NEW_USER/\$dir" "\$BOOKMARKS" || echo "file:///home/$NEW_USER/\$dir" >> "\$BOOKMARKS"
done
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER

# ============================================================
# AUR APPS
# ============================================================
aur_install google-chrome visual-studio-code-bin

# ============================================================
# SPOTIFY (+ adblock)
# ============================================================
# makepkg verifies the Spotify repo signature, so the key goes into the build
# user's keyring first (build failing? compare validpgpkeys on the AUR page).
# ~/.gnupg is made first so gpg keeps a plain pubring.kbx: a homedir gpg
# creates itself uses the keyboxd daemon, whose lock (stamped with the live
# ISO's hostname) is never released on the installed system and hangs every
# later gpg call, the build's signature check included.
GNUPG_DIR=/home/$NEW_USER/.gnupg
sudo -u "$NEW_USER" install -d -m 700 "\$GNUPG_DIR"
sed -i '/^use-keyboxd/d' "\$GNUPG_DIR/common.conf" 2>/dev/null || true
rm -f "\$GNUPG_DIR"/public-keys.d/*.lock
sudo -u "$NEW_USER" -H bash -c 'curl -fsSL https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.gpg | gpg --import -' \
    || echo "WARNING: could not import the Spotify signing key, the spotify build will fail"
aur_install spotify spotify-adblock-git
# No gpg daemon or lock may outlive the chroot.
sudo -u "$NEW_USER" -H gpgconf --kill all 2>/dev/null || true
rm -f "\$GNUPG_DIR"/*.lock "\$GNUPG_DIR"/public-keys.d/*.lock

# One launcher entry with the adblocker preloaded (/usr/local/share outranks
# /usr/share); the package's own "Spotify (adblock)" entry is hidden.
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
# Dependency-pulled developer tools and utilities; entries not installed yet
# (they come with hyprland.sh) get a placeholder.
hide_desktop_entry \
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
# Domains=~. makes these resolvers win over DHCP-provided DNS on every network
# (dead router DNS servers would stall every lookup); resolved also caches.
# LAN hostnames only the router knows won't resolve. /etc/resolv.conf is
# pointed at the stub after the chroot (arch-chroot bind-mounts the ISO's).
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
if [[ "$VIRT" == none ]]; then
    systemctl enable battery-charge-threshold.service
fi
# Keeps the ESP's systemd-boot current after systemd upgrades.
systemctl enable systemd-boot-update.service
systemctl --global enable pipewire pipewire-pulse wireplumber

systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service

# ============================================================
# FAILED PACKAGE REPORT
# ============================================================
if (( \${#FAILED_PKGS[@]} )); then
    printf '%s\n' "\${FAILED_PKGS[@]}" > /home/$NEW_USER/failed-packages.txt
    chown $NEW_USER:$NEW_USER /home/$NEW_USER/failed-packages.txt
    echo "WARNING: these packages failed to install (saved to ~/failed-packages.txt):"
    printf '  %s\n' "\${FAILED_PKGS[@]}"
    echo 'Retry after reboot with: yay -S --needed \$(cat ~/failed-packages.txt)'
fi

echo "INSTALLATION COMPLETE"
EOF

# ============================================================
# RUN CHROOT SCRIPT
# ============================================================
chmod 700 /mnt/next.sh
arch-chroot /mnt /next.sh
rm /mnt/next.sh

# ============================================================
# PASSWORDS AND FULL NAME (post-chroot)
# ============================================================
# Out here, not in next.sh: that file is an unquoted heredoc, so special
# characters would be mangled and the password would sit on disk in plaintext.
printf '%s:%s\n' "$NEW_USER" "$PASSWORD" | arch-chroot /mnt chpasswd
printf '%s:%s\n' root "$PASSWORD" | arch-chroot /mnt chpasswd
arch-chroot /mnt usermod -c "$NAME" "$NEW_USER"

# ============================================================
# DNS STUB RESOLVER (post-chroot)
# ============================================================
# Out here because arch-chroot bind-mounts the live ISO's resolv.conf.
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

# ============================================================
# DONE
# ============================================================
echo "DONE. You can reboot now."
