#!/usr/bin/env bash
# Installs VirtualBox (the VM host application) on Arch Linux: the app, its
# kernel modules (built by dkms) and the Guest Additions ISO, and adds you to
# the vboxusers group (USB passthrough).
#
# Usage: ./virtualbox.sh           install
#        ./virtualbox.sh remove    uninstall again (see remove below)
# Run it as your normal user; sudo asks for the password.
# Safe to re-run: every step is skipped if already done.

set -euo pipefail

# NOTE for editing: because of "pipefail", never write "command | grep -q"
# (see kvm.sh). Use "command | grep ... >/dev/null" instead, as below.

VBOX_PACKAGES=(virtualbox virtualbox-host-dkms virtualbox-guest-iso)

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- remove ("./virtualbox.sh remove") ---------------------------------------

# Undoes the install: the packages, the loaded kernel modules and the
# vboxusers membership. Kept: your VMs (~/VirtualBox VMs), VirtualBox's
# settings (~/.config/VirtualBox) and the kernel headers, which other dkms
# modules may need.
remove() {
    local -a installed
    local module loaded

    if pgrep -x 'VirtualBoxVM|VBoxHeadless|VBoxSDL' >/dev/null; then
        die "a VirtualBox VM is running - shut it down, then run this again"
    fi

    info "Uninstalling VirtualBox"
    mapfile -t installed < <(pacman -Qq "${VBOX_PACKAGES[@]}" 2>/dev/null)
    if (( ${#installed[@]} )); then
        # -s also removes their dependencies that nothing else uses (dkms,
        # for example), -n their config files.
        sudo pacman -Rns --noconfirm "${installed[@]}"
    else
        echo "Not installed, skipping."
    fi

    # pacman leaves loaded modules loaded. The two network modules go first,
    # because they use vboxdrv. rmmod, not modprobe -r: it still works now
    # that the module files are gone.
    info "Unloading the VirtualBox kernel modules"
    loaded=0
    for module in vboxnetflt vboxnetadp vboxdrv; do
        [[ -d /sys/module/$module ]] || continue
        loaded=1
        if sudo rmmod "$module"; then
            echo "Unloaded $module."
        else
            warn "$module is still loaded - it is gone after the next reboot"
        fi
    done
    (( loaded )) || echo "None loaded, skipping."

    info "Removing $USER from the vboxusers group"
    if id -nG "$USER" | grep -w vboxusers >/dev/null; then
        sudo gpasswd -d "$USER" vboxusers >/dev/null
        echo "Removed. Takes effect after you log out and back in."
    else
        echo "Not a member, skipping."
    fi

    info "Done"
    cat <<'EOF'
Kept: your VMs (~/VirtualBox VMs), VirtualBox's settings
(~/.config/VirtualBox) and the kernel headers.
EOF
}

# --- preflight ---------------------------------------------------------------

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (that user is the one added to vboxusers)"
command -v pacman >/dev/null || die "pacman not found - this script is for Arch Linux"

case "${1:-}" in
    "")     ;;
    remove) remove; exit 0 ;;
    *)      die "unknown argument '$1' - run without arguments to install, or with: remove" ;;
esac

VIRT=$(systemd-detect-virt --vm 2>/dev/null) || VIRT=none
if [[ $VIRT != none ]]; then
    warn "this machine is itself a $VIRT VM - VirtualBox VMs only start here if its host passes hardware virtualization through (nested virtualization)"
fi

# --- packages ----------------------------------------------------------------

# The host modules come from dkms (Arch dropped the prebuilt package); the
# dkms hook rebuilds them on kernel upgrades. dkms needs the headers of every
# installed kernel. A headers package that is already installed is left alone,
# so that it can't get ahead of its kernel.
PACKAGES=("${VBOX_PACKAGES[@]}")
for pkgbase in /usr/lib/modules/*/pkgbase; do
    [[ -f $pkgbase ]] || continue
    headers="$(<"$pkgbase")-headers"
    pacman -Qq "$headers" &>/dev/null && continue
    if pacman -Si "$headers" &>/dev/null; then
        PACKAGES+=("$headers")
    else
        warn "$headers is not installed and not in the repos - without it the modules are not built for that kernel"
    fi
done

info "Installing VirtualBox"
sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"

# --- kernel modules ----------------------------------------------------------

# The package loads them at every boot (modules-load.d); this is for now.
info "Loading the VirtualBox kernel modules"
if [[ ! -d /usr/lib/modules/$(uname -r) ]]; then
    # pacman removed the running kernel's modules, the new ones need a boot.
    warn "the kernel was updated since the last boot (still running $(uname -r)) - reboot before starting a VM"
elif sudo modprobe -a vboxdrv vboxnetadp vboxnetflt; then
    echo "Loaded."
else
    warn "the modules did not load, so VMs will not start - check: dkms status"
fi

# --- group -------------------------------------------------------------------

info "Adding $USER to the vboxusers group (USB passthrough)"
if id -nG "$USER" | grep -w vboxusers >/dev/null; then
    echo "Already a member, skipping."
else
    sudo usermod -aG vboxusers "$USER"
    echo "Added. Takes effect after you log out and back in."
fi

# --- done --------------------------------------------------------------------

info "Done"
cat <<'EOF'
Start it from the launcher, or run:  virtualbox

Guest Additions (inside a running VM: Devices -> Insert Guest Additions CD
image) come from:
  /usr/lib/virtualbox/additions/VBoxGuestAdditions.iso
EOF
