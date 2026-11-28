#!/usr/bin/env bash
#
# setup-windows-vm.sh — interactively create a Windows KVM virtual machine on
# Arch Linux using only CLI tools. Asks for the Windows version, RAM, CPU
# cores and disk size, then builds the VM. Can also add a Hyprland keyboard
# shortcut (Super+Shift+Enter) that launches the VM.
#
# USAGE
#   1. Put the Windows ISO at  ~/Downloads/win.iso   (64-bit editions only)
#   2. Run:  ./setup-windows-vm.sh      (as your normal user, NOT with sudo;
#                                        the script asks for sudo when needed)
#   3. Answer the questions. Pressing Enter accepts the [default].
#
# Each Windows version gets its own VM (win7, win81, win10, win11), so you can
# run the script again with a different ISO to add another one. It refuses to
# touch a VM that already exists.
#
# REMOVING
#   Run:  ./setup-windows-vm.sh remove
#   It asks, one by one, whether to delete each VM this script made (with its
#   disk), the keyboard shortcut, and KVM itself (the packages). Nothing is
#   removed until you confirm the summary at the end. The shared folder and
#   your Windows ISO are always kept.
#
# WHAT DIFFERS PER VERSION
#   Windows 10 / 11 : fast virtio disk + network, and a shared folder
#                     (~/share shows up as drive Z:). Needs drivers loaded
#                     during setup; the script tells you when.
#   All versions    : shared clipboard (copy/paste text between Arch and
#                     Windows) once the guest tools are installed in Windows.
#   Windows 7 / 8.1 : emulated SATA disk + Intel network card, which work
#                     without extra drivers. Slower, and NO shared folder,
#                     because current virtio drivers no longer support them.
#
set -euo pipefail

# NOTE for editing: because of "pipefail", never write "command | grep -q".
# grep -q quits at the first match, the command feeding it is then killed
# while still writing, and the whole pipe counts as failed even though the
# text was found. Use "command | grep ... >/dev/null" instead, as below.

###############################################################################
# SETTINGS — things the script does not ask about. Edit before running.
###############################################################################

# The Windows ISO to install from.
WIN_ISO="$HOME/Downloads/win.iso"

# Folder on the host that Windows 10/11 will see as a drive (Z: by default).
# Created if it does not exist.
SHARE_DIR="$HOME/share"

# Name of the share as the guest sees it.
SHARE_TAG="share"

# Where VM disks and ISOs are stored. This is libvirt's standard location; if
# you change it, pick a folder outside your home directory, because the VM
# process is not allowed to read inside /home.
IMAGES_DIR="/var/lib/libvirt/images"

# Download URL of the virtio driver ISO (only used for Windows 10/11).
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Keyboard shortcut (optional, the script asks). If you say yes, the script
# writes a small launcher program to LAUNCHER and appends one line to your
# Hyprland keybinds file that runs it on SHORTCUT_KEYS.
#   - The launcher starts the VM if it is off and opens its screen fullscreen.
#   - There is only one shortcut: it always launches the VM you set up last.
#   - To use other keys, change SHORTCUT_KEYS here before running, or edit the
#     line at the end of the keybinds file afterwards.
HYPR_KEYBINDS="$HOME/.config/hypr/conf/keybinds.lua"
LAUNCHER="$HOME/.local/bin/windows-vm"
SHORTCUT_KEYS="SUPER + SHIFT + RETURN"

# RAM (GB) always left for the Arch host. The script will not let you give
# the VM more than "total RAM minus this".
HOST_RESERVED_GB=3

###############################################################################
# PER-VERSION DEFAULTS — the [default] and minimum values offered in the
# questions. Edit the numbers here if you want different suggestions.
#
#   VM_NAME      name used in virsh commands
#   OS_VARIANT   tells virt-install which Windows this is
#   MODERN       yes = virtio devices + shared folder, no = SATA/Intel, no share
#   DRIVER_DIR   folder on the virtio driver CD (MODERN=yes only)
#   NET_MODEL    network card type
#   USE_UEFI     yes = UEFI firmware, no = legacy BIOS (Windows 7 needs BIOS)
#   USE_TPM      yes = add a virtual TPM (Windows 11 requires it)
#   *_DEF/*_MIN  default and minimum RAM (GB) and disk (GB)
###############################################################################

set_version() {
    case "$1" in
        7)
            VM_NAME="win7";  OS_VARIANT="win7";   MODERN=no;  DRIVER_DIR=""
            NET_MODEL="e1000";  USE_UEFI=no;  USE_TPM=no
            RAM_DEF=4; RAM_MIN=2; DISK_DEF=40; DISK_MIN=25 ;;
        8|8.1)
            VM_NAME="win81"; OS_VARIANT="win8.1"; MODERN=no;  DRIVER_DIR=""
            NET_MODEL="e1000e"; USE_UEFI=yes; USE_TPM=no
            RAM_DEF=4; RAM_MIN=2; DISK_DEF=40; DISK_MIN=25 ;;
        10)
            VM_NAME="win10"; OS_VARIANT="win10";  MODERN=yes; DRIVER_DIR="w10"
            NET_MODEL="virtio"; USE_UEFI=yes; USE_TPM=no
            RAM_DEF=8; RAM_MIN=2; DISK_DEF=80; DISK_MIN=32 ;;
        11)
            VM_NAME="win11"; OS_VARIANT="win11";  MODERN=yes; DRIVER_DIR="w11"
            NET_MODEL="virtio"; USE_UEFI=yes; USE_TPM=yes
            RAM_DEF=8; RAM_MIN=4; DISK_DEF=80; DISK_MIN=64 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# END OF SETTINGS — you normally do not need to edit below this line.
###############################################################################

URI="qemu:///system"
VIRTIO_ISO="$IMAGES_DIR/virtio-win.iso"

# Every VM_NAME from set_version above. Remove mode looks for these.
SCRIPT_VMS=(win7 win81 win10 win11)

# The packages the script installs (swtpm only for Windows 11). Remove mode
# uninstalls the same list.
KVM_PACKAGES=(qemu-desktop libvirt virt-install virt-viewer dnsmasq edk2-ovmf virtiofsd)
TPM_PACKAGES=(swtpm)

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ask_yes_no "question" y|n  -> succeeds on yes. Enter picks the given default.
ask_yes_no() {
    local prompt=$1 def=$2 hint="[y/N]" answer
    [ "$def" = y ] && hint="[Y/n]"
    read -rp "$prompt $hint: " answer || die "No input."
    case "${answer:-$def}" in
        y|Y|yes|Yes) return 0 ;;
        *)           return 1 ;;
    esac
}

# Run a command with the libvirt group active. Needed because a group you were
# just added to only applies to your shell after you log out and back in.
as_libvirt() {
    if id -nG | grep -w libvirt >/dev/null; then
        "$@"
    else
        sg libvirt -c "$(printf '%q ' "$@")"
    fi
}

# ask_number "question" default min max  -> prints the chosen whole number
ask_number() {
    local prompt=$1 def=$2 min=$3 max=$4 answer
    while true; do
        read -rp "$prompt [$def]: " answer || die "No input."
        answer=${answer:-$def}
        if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= min && answer <= max )); then
            echo "$answer"
            return
        fi
        echo "  Please enter a whole number between $min and $max." >&2
    done
}

# Write the launcher and add the Hyprland keybind (only if the user said yes).
add_shortcut() {
    [ "$WANT_SHORTCUT" = yes ] || return 0

    say "Setting up the $SHORTCUT_KEYS shortcut"

    # The launcher is rewritten every time, so the shortcut follows the VM
    # you set up most recently.
    mkdir -p "$(dirname "$LAUNCHER")"
    cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Launches the Windows VM: starts it if it is off, then opens its screen.
# Written by setup-windows-vm.sh.
#   - Change VM to launch a different one (see: virsh list --all).
#   - Remove "-f" below to open a normal window instead of fullscreen.
#     Shift+F11 toggles fullscreen, Shift+F12 releases the mouse.
VM="$VM_NAME"
URI="$URI"
virsh -c "\$URI" start "\$VM" >/dev/null 2>&1
exec virt-viewer -f -c "\$URI" "\$VM"
EOF
    chmod +x "$LAUNCHER"
    echo "    Launcher written: $LAUNCHER  (launches $VM_NAME)"

    # The keybind line is only added once.
    if grep -qF "$LAUNCHER" "$HYPR_KEYBINDS"; then
        echo "    Keybind already present in $HYPR_KEYBINDS"
        return 0
    fi

    cp "$HYPR_KEYBINDS" "$HYPR_KEYBINDS.bak"
    cat >> "$HYPR_KEYBINDS" <<EOF

-- Windows VM (added by setup-windows-vm.sh): start it and open its screen
hl.bind("$SHORTCUT_KEYS", hl.dsp.exec_cmd("$LAUNCHER"))
EOF
    echo "    Keybind added to: $HYPR_KEYBINDS  (backup: $HYPR_KEYBINDS.bak)"
    hyprctl reload >/dev/null 2>&1 || true
}

# --- Remove mode ("./setup-windows-vm.sh remove") ----------------------------

# Succeeds if VM $1 is switched on (running or paused).
vm_is_active() {
    sudo virsh -c "$URI" list --name | grep -Fx "$1" >/dev/null
}

# Prints the files that belong to VM $1 alone, one per line: its disk image(s)
# and its copy of the Windows ISO. The virtio driver CD is shared between VMs,
# so it is not listed.
vm_files() {
    sudo virsh -c "$URI" domblklist "$1" --details \
        | awk '$1 == "file" && $2 == "disk" && $4 != "-" {
                   sub(/^ *[^ ]+ +[^ ]+ +[^ ]+ +/, ""); print }'
    if sudo test -e "$IMAGES_DIR/$1-install.iso"; then
        echo "$IMAGES_DIR/$1-install.iso"
    fi
}

# Switch VM $1 off, delete its definition and the files from vm_files.
delete_vm() {
    local name=$1 file
    local -a files
    say "Deleting VM $name"
    mapfile -t files < <(vm_files "$name")

    if vm_is_active "$name"; then
        echo "    It is running: switching it off"
        sudo virsh -c "$URI" destroy "$name" >/dev/null
    fi

    # --nvram deletes the UEFI settings file. The other flags drop a saved
    # state and snapshot records; libvirt refuses to delete a VM that still
    # has them.
    sudo virsh -c "$URI" undefine "$name" --nvram --managed-save \
        --snapshots-metadata --checkpoints-metadata >/dev/null

    # Through libvirt where it tracks the file (so its list stays correct),
    # plainly otherwise.
    for file in "${files[@]}"; do
        sudo virsh -c "$URI" vol-delete "$file" >/dev/null 2>&1 || sudo rm -f -- "$file"
        echo "    Deleted $file"
    done
}

# Delete the launcher and take its lines back out of the Hyprland keybinds:
# the bind line, plus the comment and the blank line add_shortcut put above it.
remove_shortcut() {
    say "Removing the keyboard shortcut"
    rm -f "$LAUNCHER"
    echo "    Deleted $LAUNCHER"

    if [ -f "$HYPR_KEYBINDS" ] && grep -qF "$LAUNCHER" "$HYPR_KEYBINDS"; then
        cp "$HYPR_KEYBINDS" "$HYPR_KEYBINDS.bak"
        awk -v launcher="$LAUNCHER" '
            function flush(   i) { for (i = 1; i <= held; i++) print line[i]; held = 0 }
            index($0, launcher) {
                if (held && line[held] !~ /^-- Windows VM \(added by /) flush()
                held = 0
                next
            }
            /^[[:space:]]*$/ { flush(); line[++held] = $0; next }
            /^-- Windows VM \(added by / {
                if (!(held == 1 && line[1] ~ /^[[:space:]]*$/)) flush()
                line[++held] = $0
                next
            }
            { flush(); print }
            END { flush() }
        ' "$HYPR_KEYBINDS.bak" > "$HYPR_KEYBINDS"
        echo "    Keybind removed from: $HYPR_KEYBINDS  (backup: $HYPR_KEYBINDS.bak)"
        hyprctl reload >/dev/null 2>&1 || true
    fi
}

# Undo steps 1 and 2 of the setup: the packages, the service, the network and
# the group membership. Also deletes the downloaded virtio driver ISO.
remove_kvm() {
    local -a installed
    say "Uninstalling KVM"

    # pacman does not stop anything, so the network (the virbr0 bridge and its
    # dnsmasq) and the services are stopped before their files go.
    if command -v virsh >/dev/null; then
        sudo virsh -c "$URI" net-destroy default >/dev/null 2>&1 || true
        sudo virsh -c "$URI" net-autostart --disable default >/dev/null 2>&1 || true
    fi
    sudo systemctl disable --now libvirtd.service >/dev/null 2>&1 || true
    sudo systemctl stop 'libvirtd*' 'virtlogd*' 'virtlockd*' >/dev/null 2>&1 || true

    # -s also removes their dependencies that nothing else uses, -n their
    # config files. -u leaves out a package that something else still needs,
    # instead of failing.
    mapfile -t installed < <(pacman -Qq "${KVM_PACKAGES[@]}" "${TPM_PACKAGES[@]}" 2>/dev/null)
    if [ ${#installed[@]} -gt 0 ]; then
        sudo pacman -Rnsu --noconfirm "${installed[@]}" \
            || echo "    pacman did not remove everything, see its messages above."
    fi

    sudo rm -f -- "$VIRTIO_ISO" "$VIRTIO_ISO.part"

    if getent group libvirt | grep -w "$USER" >/dev/null; then
        sudo gpasswd -d "$USER" libvirt >/dev/null
        echo "    $USER left the libvirt group."
    fi
}

remove_mode() {
    local name state file shortcut_vm def all_vms=""
    local -a found=() chosen=() remaining=() installed=()
    local want_shortcut=no want_kvm=no

    # --- Questions ---

    if command -v virsh >/dev/null; then
        # VMs can only be listed while libvirtd runs.
        sudo virsh -c "$URI" uri >/dev/null 2>&1 || sudo systemctl start libvirtd \
            || die "libvirtd does not start, so the VMs cannot be listed."
        all_vms=$(sudo virsh -c "$URI" list --all --name)
        for name in "${SCRIPT_VMS[@]}"; do
            if grep -Fx "$name" <<<"$all_vms" >/dev/null; then
                found+=("$name")
            fi
        done
    fi

    echo
    if [ ${#found[@]} -eq 0 ]; then
        echo "No VM made by this script exists (looked for: ${SCRIPT_VMS[*]})."
    fi
    for name in "${found[@]}"; do
        state=off
        if vm_is_active "$name"; then state=running; fi
        if ask_yes_no "Delete VM '$name' ($state) and its disk? Everything inside that Windows is lost." n; then
            chosen+=("$name")
        fi
    done

    # Every VM that will still exist afterwards, including ones not made here.
    while read -r name; do
        [ -n "$name" ] || continue
        [[ " ${chosen[*]} " == *" $name "* ]] || remaining+=("$name")
    done <<<"$all_vms"

    # The shortcut: suggested for removal unless the VM it launches stays.
    if [ -e "$LAUNCHER" ] || { [ -f "$HYPR_KEYBINDS" ] && grep -qF "$LAUNCHER" "$HYPR_KEYBINDS"; }; then
        shortcut_vm=""
        if [ -f "$LAUNCHER" ]; then
            shortcut_vm=$(sed -n 's/^VM="\(.*\)"$/\1/p' "$LAUNCHER")
        fi
        def=y
        if [[ -n $shortcut_vm && " ${remaining[*]} " == *" $shortcut_vm "* ]]; then def=n; fi
        if ask_yes_no "Remove the keyboard shortcut${shortcut_vm:+ that launches $shortcut_vm}?" "$def"; then
            want_shortcut=yes
        fi
    fi

    # KVM itself: only offered when no VM at all is left that needs it.
    mapfile -t installed < <(pacman -Qq "${KVM_PACKAGES[@]}" "${TPM_PACKAGES[@]}" 2>/dev/null)
    if [ ${#installed[@]} -gt 0 ]; then
        if [ ${#remaining[@]} -gt 0 ]; then
            echo "(KVM itself is kept, because these VMs remain: ${remaining[*]})"
        elif ask_yes_no "Also uninstall KVM itself (packages, driver ISO, libvirt group)?" n; then
            want_kvm=yes
        fi
    fi

    if [ ${#chosen[@]} -eq 0 ] && [ "$want_shortcut" = no ] && [ "$want_kvm" = no ]; then
        echo
        echo "Nothing selected. Nothing was changed."
        return 0
    fi

    # --- Summary ---

    echo
    echo "About to remove:"
    for name in "${chosen[@]}"; do
        echo "    VM            $name"
        while read -r file; do
            echo "                  $file"
        done < <(vm_files "$name")
    done
    if [ "$want_shortcut" = yes ]; then
        echo "    Shortcut      $LAUNCHER"
        echo "                  and its lines in $HYPR_KEYBINDS"
    fi
    if [ "$want_kvm" = yes ]; then
        echo "    Packages      ${installed[*]}"
        echo "                  and their dependencies that nothing else uses"
        echo "    Driver ISO    $VIRTIO_ISO"
        echo "    Group         $USER leaves the libvirt group"
    fi
    echo
    echo "Kept: $SHARE_DIR and $WIN_ISO"
    echo
    if ! ask_yes_no "Continue?" n; then
        echo "Cancelled. Nothing was changed."
        return 0
    fi

    # --- Removal ---

    for name in "${chosen[@]}"; do
        delete_vm "$name"
    done
    if [ "$want_shortcut" = yes ]; then remove_shortcut; fi
    if [ "$want_kvm" = yes ]; then remove_kvm; fi

    say "Done."
}

# --- Checks -----------------------------------------------------------------

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not as root or with sudo."

# With "remove" as the argument the script removes instead of creating.
case "${1:-}" in
    "")     ;;
    remove) remove_mode; exit 0 ;;
    *)      die "Unknown argument '$1'. Run without arguments to create a VM, or with: remove" ;;
esac

[ -e /dev/kvm ]      || die "/dev/kvm not found. Enable virtualization (VT-x / AMD-V / SVM) in your BIOS."
[ -f "$WIN_ISO" ]    || die "Windows ISO not found at: $WIN_ISO"

# After a kernel update pacman removes the running kernel's modules, so the
# network modules libvirt needs can no longer be loaded until the next boot.
[ -d "/usr/lib/modules/$(uname -r)" ] \
    || die "The kernel was updated since the last boot (still running $(uname -r)). Reboot, then run this script again."

# --- Questions --------------------------------------------------------------

HOST_CORES=$(nproc)
HOST_RAM_GB=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024 / 1024 + 0.5}' /proc/meminfo)
RAM_MAX=$(( HOST_RAM_GB - HOST_RESERVED_GB ))

echo
echo "This computer has $HOST_CORES CPU threads and about $HOST_RAM_GB GB of RAM."
echo "Installing from: $WIN_ISO"
echo

while true; do
    read -rp "Which Windows version is that ISO? (7, 8.1, 10, 11) [10]: " WIN_VERSION || die "No input."
    WIN_VERSION=${WIN_VERSION:-10}
    set_version "$WIN_VERSION" && break
    echo "  Please answer 7, 8.1, 10 or 11." >&2
done

(( RAM_MAX >= RAM_MIN )) || die "Not enough RAM on this computer for Windows $WIN_VERSION."
(( RAM_DEF <= RAM_MAX )) || RAM_DEF=$RAM_MAX

CORES_MIN=1
[ "$WIN_VERSION" = 11 ] && CORES_MIN=2
CORES_DEF=$(( HOST_CORES / 2 ))
(( CORES_DEF >= CORES_MIN )) || CORES_DEF=$CORES_MIN

RAM_GB=$(ask_number  "RAM for the VM in GB ($RAM_MIN-$RAM_MAX)" "$RAM_DEF" "$RAM_MIN" "$RAM_MAX")
VCPUS=$(ask_number   "CPU cores for the VM ($CORES_MIN-$HOST_CORES)" "$CORES_DEF" "$CORES_MIN" "$HOST_CORES")
DISK_GB=$(ask_number "Disk size in GB (min $DISK_MIN, grows on demand)" "$DISK_DEF" "$DISK_MIN" 2000)

# Shortcut question: only asked when a Hyprland keybinds file exists and the
# keys are not already used by something else in it.
WANT_SHORTCUT=no
SHORTCUT_PATTERN=$(printf '%s' "$SHORTCUT_KEYS" | sed 's/ *+ */ *[+] */g')
if [ ! -f "$HYPR_KEYBINDS" ]; then
    echo "(No Hyprland keybinds file at $HYPR_KEYBINDS, skipping the shortcut question.)"
elif grep -vF "$LAUNCHER" "$HYPR_KEYBINDS" | grep -v '^[[:space:]]*--' \
        | sed 's/mainMod *\.\. *"/"SUPER/g' | grep -iE "\"$SHORTCUT_PATTERN\"" >/dev/null; then
    echo "($SHORTCUT_KEYS is already used in $HYPR_KEYBINDS, skipping the shortcut question.)"
else
    read -rp "Add a $SHORTCUT_KEYS shortcut to launch this VM? [y/N]: " ANSWER || die "No input."
    case "$ANSWER" in
        y|Y|yes|Yes) WANT_SHORTCUT=yes ;;
    esac
fi

RAM_MB=$(( RAM_GB * 1024 ))
DISK_PATH="$IMAGES_DIR/$VM_NAME.qcow2"
WIN_ISO_COPY="$IMAGES_DIR/$VM_NAME-install.iso"

echo
echo "About to create this VM:"
echo "    Name          $VM_NAME"
echo "    Windows       $WIN_VERSION"
echo "    RAM           $RAM_GB GB"
echo "    CPU cores     $VCPUS"
echo "    Disk          $DISK_GB GB  ($DISK_PATH)"
if [ "$MODERN" = yes ]; then
    echo "    Shared folder $SHARE_DIR  (drive Z: in Windows)"
else
    echo "    Shared folder not available for Windows $WIN_VERSION"
fi
if [ "$WANT_SHORTCUT" = yes ]; then
    echo "    Shortcut      $SHORTCUT_KEYS  (added to $HYPR_KEYBINDS)"
else
    echo "    Shortcut      none"
fi
echo
read -rp "Continue? [Y/n]: " CONFIRM || die "No input."
case "${CONFIRM:-y}" in
    y|Y|yes|Yes) ;;
    *) echo "Cancelled. Nothing was changed."; exit 0 ;;
esac

# --- 1. Packages ------------------------------------------------------------

say "Installing packages"
PACKAGES=("${KVM_PACKAGES[@]}")
[ "$USE_TPM" = yes ] && PACKAGES+=("${TPM_PACKAGES[@]}")
sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"

# --- 2. libvirt service, group and network ----------------------------------

say "Enabling libvirtd"
sudo systemctl enable --now libvirtd

if ! getent group libvirt | grep -w "$USER" >/dev/null; then
    say "Adding $USER to the libvirt group (takes full effect after you log out and in)"
    sudo usermod -aG libvirt "$USER"
fi

say "Starting the default NAT network"
if ! sudo virsh -c "$URI" net-info default | grep 'Active: *yes' >/dev/null; then
    sudo virsh -c "$URI" net-start default
fi
sudo virsh -c "$URI" net-autostart default

# --- 3. Stop here if the VM already exists ----------------------------------

if sudo virsh -c "$URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
    add_shortcut
    say "A VM named '$VM_NAME' already exists — it was left as it is."
    echo "Start it with:   virsh -c $URI start $VM_NAME"
    echo "Open its screen: virt-viewer -c $URI $VM_NAME"
    echo "To recreate it, delete it first:  $0 remove"
    exit 0
fi

# --- 4. ISOs and shared folder ----------------------------------------------

say "Copying the Windows ISO to $IMAGES_DIR"
sudo cp "$WIN_ISO" "$WIN_ISO_COPY"

if [ "$MODERN" = yes ]; then
    if [ ! -f "$VIRTIO_ISO" ]; then
        say "Downloading the virtio driver ISO"
        sudo curl --fail --location --output "$VIRTIO_ISO.part" "$VIRTIO_URL"
        sudo mv "$VIRTIO_ISO.part" "$VIRTIO_ISO"
    fi
    mkdir -p "$SHARE_DIR"
fi

add_shortcut

# --- 5. Create the VM -------------------------------------------------------

echo
echo "==> Creating the VM. A window with the Windows installer opens now."
echo
echo "    IN THE WINDOW:"
echo "    * Press a key right away if you see \"Press any key to boot from CD\"."
echo "      If you miss it, run in another terminal:"
echo "          virsh -c $URI reset $VM_NAME"
if [ "$MODERN" = yes ]; then
    echo "    * When the installer shows no disks: click \"Load driver\", browse the"
    echo "      virtio-win CD and pick   viostor\\$DRIVER_DIR\\amd64"
    echo "      (do the same with       NetKVM\\$DRIVER_DIR\\amd64   if you need network)."
fi
echo

# What each option does, in case you want to adapt this command:
#   --cpu host-passthrough   give the guest your real CPU model (fastest)
#   --disk ...bus=           virtio = fast, needs a driver; sata = works anywhere
#   --network ...model=      virtio = fast, needs a driver; e1000/e1000e = built in
#   --boot uefi              UEFI firmware instead of legacy BIOS
#   --tpm                    virtual TPM 2.0 (Windows 11)
#   --memorybacking          shared memory, required by the shared folder
#   --filesystem             the shared folder itself (virtiofs)
#   --graphics spice         the display that virt-viewer connects to
#   --channel spicevmc       link to the SPICE agent in Windows: shared clipboard
#                            (copy/paste text both ways) and auto-resizing screen
VIRT_ARGS=(
    --connect "$URI"
    --name "$VM_NAME"
    --os-variant "$OS_VARIANT"
    --memory "$RAM_MB"
    --vcpus "$VCPUS"
    --cpu host-passthrough
    --cdrom "$WIN_ISO_COPY"
    --network "network=default,model=$NET_MODEL"
    --graphics spice
    --video qxl
    --channel spicevmc,target.type=virtio,target.name=com.redhat.spice.0
)

if [ "$MODERN" = yes ]; then
    VIRT_ARGS+=(
        --disk "path=$DISK_PATH,size=$DISK_GB,format=qcow2,bus=virtio"
        --disk "path=$VIRTIO_ISO,device=cdrom"
        --memorybacking source.type=memfd,access.mode=shared
        --filesystem "source.dir=$SHARE_DIR,target.dir=$SHARE_TAG,driver.type=virtiofs"
    )
else
    VIRT_ARGS+=(
        --disk "path=$DISK_PATH,size=$DISK_GB,format=qcow2,bus=sata"
    )
fi

[ "$USE_UEFI" = yes ] && VIRT_ARGS+=(--boot uefi)
[ "$USE_TPM"  = yes ] && VIRT_ARGS+=(--tpm backend.type=emulator,backend.version=2.0,model=tpm-crb)

as_libvirt virt-install "${VIRT_ARGS[@]}"

# --- 6. What to do next -----------------------------------------------------

echo
echo "==> Done."
echo
if [ "$MODERN" = yes ]; then
    echo "    Finish these steps INSIDE WINDOWS to get the shared clipboard and"
    echo "    the shared folder:"
    echo
    echo "    1. Open the virtio-win CD and run  virtio-win-guest-tools.exe"
    echo "       (this also turns on copy/paste between Arch and Windows)"
    echo "    2. Install WinFsp from https://winfsp.dev"
    echo "    3. In an Administrator terminal:"
    echo "           sc config VirtioFsSvc start=auto"
    echo "           sc start VirtioFsSvc"
    echo "       $SHARE_DIR then shows up as drive Z:"
else
    echo "    No shared folder was set up for Windows $WIN_VERSION."
    echo "    To move files, share a folder from Arch over the network (Samba);"
    echo "    the VM reaches this computer at the address 192.168.122.1."
    echo
    echo "    For copy/paste between Arch and Windows, install inside Windows:"
    echo "        https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe"
fi
echo
echo "    Daily use (after logging out and in once, add this to ~/.zshrc so you"
echo "    can drop the \"-c $URI\" part:  export LIBVIRT_DEFAULT_URI=$URI ):"
echo
echo "        virsh -c $URI start $VM_NAME"
echo "        virt-viewer -c $URI $VM_NAME"
echo "        virsh -c $URI shutdown $VM_NAME"
if [ "$WANT_SHORTCUT" = yes ]; then
    echo
    echo "    Or press $SHORTCUT_KEYS: it starts the VM and opens it fullscreen"
    echo "    (Shift+F11 leaves fullscreen)."
fi
echo
echo "    Copy/paste works while the virt-viewer window is focused. If it does"
echo "    not work under Wayland, open the window like this instead:"
echo "        GDK_BACKEND=x11 virt-viewer -c $URI $VM_NAME"
echo

###############################################################################
# CHANGING SETTINGS LATER
#
# Once a VM exists, change it with virsh (shut the VM down first).
# Replace NAME with win7, win81, win10 or win11.
#
# Memory (here: 12 GB):
#     virsh setmaxmem NAME 12G --config
#     virsh setmem    NAME 12G --config
#
# CPU cores (here: 6):
#     virsh setvcpus NAME 6 --config --maximum
#     virsh setvcpus NAME 6 --config
#
# Bigger disk (here: +40 GB), then extend C: in Windows "Disk Management":
#     sudo qemu-img resize /var/lib/libvirt/images/NAME.qcow2 +40G
#
# Different or additional shared folder, or anything else:
#     virsh edit NAME
#   and edit / duplicate the <filesystem> block. Each share needs its own
#   <target dir='...'/> name.
#
# Start the VM automatically at boot:
#     virsh autostart NAME             (undo: virsh autostart --disable NAME)
#
# Snapshot before trying something risky:
#     virsh snapshot-create-as NAME before-change
#     virsh snapshot-revert    NAME before-change
#
# List all VMs:
#     virsh list --all
#
# Keyboard shortcut:
#   - Launch a different VM with it: edit the VM="..." line in
#     ~/.local/bin/windows-vm
#   - Open in a window instead of fullscreen: remove "-f" in that same file.
#   - Change the keys: edit the last "Windows VM" lines in
#     ~/.config/hypr/conf/keybinds.lua
#     (the script saved the previous version next to it as keybinds.lua.bak).
#
# Delete a VM completely, including its disk (the shared folder is kept):
#     ./setup-windows-vm.sh remove
#   The same command removes the keyboard shortcut and can uninstall KVM
#   itself. After deleting a VM you can run this script again to recreate it.
###############################################################################
