#!/usr/bin/env bash
# Installs VirtualBox (the VM host application) on Arch Linux: the app, its
# kernel modules (built by dkms) and the Guest Additions ISO, and adds you to
# the vboxusers group (USB passthrough).
#
# Usage: ./virtualbox.sh    (as your normal user; sudo asks for the password)
# Safe to re-run: every step is skipped if already done.

set -euo pipefail

# NOTE for editing: because of "pipefail", never write "command | grep -q"
# (see kvm.sh). Use "command | grep ... >/dev/null" instead, as below.

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (that user is the one added to vboxusers)"
command -v pacman >/dev/null || die "pacman not found - this script is for Arch Linux"

VIRT=$(systemd-detect-virt --vm 2>/dev/null) || VIRT=none
if [[ $VIRT != none ]]; then
    warn "this machine is itself a $VIRT VM - VirtualBox VMs only start here if its host passes hardware virtualization through (nested virtualization)"
fi

# --- packages ----------------------------------------------------------------

# The host modules come from dkms (Arch dropped the prebuilt package); the
# dkms hook rebuilds them on kernel upgrades. dkms needs the headers of every
# installed kernel. A headers package that is already installed is left alone,
# so that it can't get ahead of its kernel.
PACKAGES=(virtualbox virtualbox-host-dkms virtualbox-guest-iso)
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
