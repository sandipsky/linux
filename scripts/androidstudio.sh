#!/usr/bin/env bash
# Sets up Android app development (Kotlin) on Arch Linux.
# Installs Android Studio (bundles Kotlin, Gradle and a JDK), udev rules for
# real devices, and adds the SDK tools to PATH in ~/.zshrc.
#
# Usage: ./setup-android-dev.sh
# Unattended: asks for the sudo password once at the start (not at all if sudo
# is passwordless or already cached), then runs to completion with no prompts.
# Safe to re-run: every step is skipped if already done.

set -euo pipefail

SDK_DIR="$HOME/Android/Sdk"
ZSHRC="$HOME/.zshrc"
MARKER="# >>> android sdk >>>"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (yay refuses to run as root)"
command -v pacman >/dev/null || die "pacman not found - this script is for Arch Linux"
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
