#!/usr/bin/env bash
# Sets up Android app development (Kotlin) on Arch Linux.
# Installs Android Studio (bundles Kotlin, Gradle and a JDK), udev rules for
# real devices, and adds the SDK tools to PATH in ~/.zshrc.
#
# Usage: ./setup-android-dev.sh           set up
#        ./setup-android-dev.sh remove    undo it again (see remove below)
# Unattended: asks for the sudo password once at the start (not at all if sudo
# is passwordless or already cached), then runs to completion with no prompts.
# Safe to re-run: every step is skipped if already done.

set -euo pipefail

SDK_DIR="$HOME/Android/Sdk"
AVD_DIR="$HOME/.android/avd"
ZSHRC="$HOME/.zshrc"
MARKER="# >>> android sdk >>>"
MARKER_END="# <<< android sdk <<<"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- remove ("./setup-android-dev.sh remove") --------------------------------

# Undoes the setup: Android Studio, the udev rules and the PATH lines in
# ~/.zshrc. The SDK and the emulator devices were downloaded by Android
# Studio, not by this script, and can be many GB: it asks once, at the start,
# whether they go too (without a terminal to ask on they are kept).
# Always kept: your projects, Android Studio's settings (~/.config/Google,
# ~/.local/share/Google, ~/.cache/Google), the adb keys and debug keystore in
# ~/.android, and ~/.gradle.
remove() {
    local -a installed data=()
    local answer=n tmp

    if [[ -d $SDK_DIR ]]; then data+=("$SDK_DIR"); fi
    if [[ -d $AVD_DIR ]]; then data+=("$AVD_DIR"); fi
    if (( ${#data[@]} )) && [[ -t 0 ]]; then
        info "The Android SDK and the emulator devices"
        du -sh "${data[@]}" 2>/dev/null || true
        read -rp "Delete them too? [y/N]: " answer || answer=n
    fi

    info "Uninstalling Android Studio and the udev rules"
    mapfile -t installed < <(pacman -Qq android-studio android-udev 2>/dev/null)
    if (( ${#installed[@]} )); then
        # -s also removes their dependencies that nothing else uses, -n their
        # config files.
        sudo pacman -Rns --noconfirm "${installed[@]}"
    else
        echo "Not installed, skipping."
    fi

    info "Removing the Android SDK tools from PATH in $ZSHRC"
    if [[ ! -f $ZSHRC ]] || ! grep -qxF "$MARKER" "$ZSHRC"; then
        echo "Not there, skipping."
    elif ! grep -qxF "$MARKER_END" "$ZSHRC"; then
        warn "found the line '$MARKER' but not '$MARKER_END' - remove the block by hand"
    else
        # Drops everything from one marker line to the other, and the empty
        # line the setup put above the block. Written to a temporary file
        # first, so a failure cannot leave ~/.zshrc half written.
        tmp=$(mktemp)
        awk -v start="$MARKER" -v end="$MARKER_END" '
            skipping    { if ($0 == end) skipping = 0; next }
            $0 == start { blank = 0; skipping = 1; next }
            blank       { print ""; blank = 0 }
            /^$/        { blank = 1; next }
                        { print }
            END         { if (blank) print "" }
        ' "$ZSHRC" > "$tmp"
        cat "$tmp" > "$ZSHRC"
        rm -f "$tmp"
        echo "Removed. Open a new terminal for it to take effect."
    fi

    if (( ${#data[@]} )); then
        info "The Android SDK and the emulator devices"
        case "$answer" in
            y|Y|yes|Yes)
                rm -rf -- "${data[@]}"
                # ~/Android itself, if the SDK was the only thing in it.
                rmdir "$(dirname "$SDK_DIR")" 2>/dev/null || true
                echo "Deleted: ${data[*]}" ;;
            *)
                echo "Kept: ${data[*]}" ;;
        esac
    fi

    info "Done"
    cat <<'EOF'
Kept: your projects, Android Studio's settings (~/.config/Google,
~/.local/share/Google, ~/.cache/Google), ~/.android and ~/.gradle.
EOF
}

# --- preflight ---------------------------------------------------------------

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (yay refuses to run as root)"
command -v pacman >/dev/null || die "pacman not found - this script is for Arch Linux"

case "${1:-}" in
    "")     ;;
    remove) remove; exit 0 ;;
    *)      die "unknown argument '$1' - run without arguments to set up, or with: remove" ;;
esac

command -v yay >/dev/null    || die "yay not found - install an AUR helper first"

# Get sudo up front, then keep it alive so the long AUR build can't outlast
# the sudo timeout and stall on a password prompt at the install step.
if ! sudo -n true 2>/dev/null; then
    [[ -t 0 ]] || die "sudo needs a password and there is no terminal to ask on - run 'sudo -v' first"
    info "Enter your sudo password once - everything after this runs unattended"
    sudo -v || die "could not get sudo"
fi
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null || true' EXIT

info "Checking hardware acceleration for the emulator"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    echo "KVM is available."
else
    warn "/dev/kvm is not accessible - the emulator will be very slow."
    warn "Enable virtualization (VT-x/AMD-V) in the BIOS, then: sudo usermod -aG kvm $USER"
fi

# --- packages ----------------------------------------------------------------

info "Installing udev rules for physical Android devices"
sudo pacman -S --needed --noconfirm android-udev

info "Installing Android Studio from the AUR (large download, takes a while)"
# --noconfirm plus the --answer* flags skip every yay menu (clean build, diff,
# PKGBUILD edit), so the PKGBUILD is not shown for review.
yay -S --needed --noconfirm \
    --answerclean None --answerdiff None --answeredit None \
    --removemake --cleanafter \
    android-studio

# --- shell environment -------------------------------------------------------

info "Adding the Android SDK tools to PATH in $ZSHRC"
if [[ -f $ZSHRC ]] && grep -qF "$MARKER" "$ZSHRC"; then
    echo "Already configured, skipping."
else
    cat >> "$ZSHRC" <<'EOF'

# >>> android sdk >>>
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"
# <<< android sdk <<<
EOF
    echo "Added. Open a new terminal or run: source $ZSHRC"
fi

# --- done --------------------------------------------------------------------

info "Done"
if [[ -d $SDK_DIR ]]; then
    echo "Android SDK found at $SDK_DIR."
else
    echo "The Android SDK is not downloaded yet - Android Studio does that on first launch."
fi

cat <<'EOF'

Next steps (these happen inside Android Studio):
  1. Run:  android-studio
  2. Setup wizard: choose "Standard" and accept the licenses (downloads the SDK
     and emulator into ~/Android/Sdk).
  3. New Project -> Empty Activity (Kotlin + Jetpack Compose).
  4. Device Manager -> Create Virtual Device, or plug in a phone with
     USB debugging enabled.
  5. Press Run (Shift+F10).

If ./gradlew in a terminal complains about the Java version, use Studio's JDK:
  export JAVA_HOME=/opt/android-studio/jbr
EOF
