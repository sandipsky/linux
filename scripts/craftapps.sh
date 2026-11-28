#!/usr/bin/env bash
# Install Craft apps from the AUR (-bin packages) and rename their launcher
# entries (Photoshop, Premiere Pro, Word, Excel, PowerPoint).
#
# Usage:  ./install-craft-apps.sh                # asks which apps to install
#         ./install-craft-apps.sh 1,3-5          # or: 1-2 | 2 | all
#         ./install-craft-apps.sh remove         # asks which apps to remove
#         ./install-craft-apps.sh remove 1,3-5   # or: 1-2 | 2 | all
#
# - Nothing is asked after the selection. If something has to be installed,
#   sudo asks for the password once, right away; from then on yay runs with
#   --noconfirm and a keepalive stops sudo from asking again.
# - An app that is already installed is not reinstalled; only its launcher
#   entry is updated.
# - The launcher entry is written to ~/.local/share/applications, which
#   overrides the packaged one in /usr/share/applications and survives
#   package updates. Delete the file there to get the original entry back.
# - The icon is the .svg from the repo's icons/ folder, which is copied into
#   ICON_DIR when it is new or has changed; without one there, whatever
#   ICON_DIR already has is used. No icon: only the name changes.
# - An app marked "nvidia" in APPS (Premiere Pro) is started through
#   prime-run, so it can only render on the NVIDIA GPU. Where prime-run is
#   not installed its Exec line is left as it is.
# - "remove" uninstalls the chosen apps and deletes their launcher entries
#   from ~/.local/share/applications. The icons in ICON_DIR are kept.

set -u

ICON_DIR=/usr/share/icons/hicolor/scalable/apps
# icons/ of the repo this script sits in; empty if the script was moved out.
REPO_ICONS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../icons" 2>/dev/null && pwd)" || REPO_ICONS=""
USER_APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

# app (binary / base package name) | launcher name | icon file names to try
# | "nvidia" to start it on the NVIDIA GPU (optional)
APPS=(
  "photocraft|Photoshop|photoshop"
  "filmcraft|Premiere Pro|premiere premiere-pro premierepro premiere_pro|nvidia"
  "wordcraft|Word|word"
  "gridcraft|Excel|excel"
  "deckcraft|PowerPoint|powerpoint"
)
N=${#APPS[@]}

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root (yay asks for sudo itself)." >&2
  exit 1
fi

# "remove" as the first argument switches from installing to removing.
MODE=install
if [[ "${1:-}" == remove ]]; then MODE=remove; shift; fi

# Name of the installed package that provides app $1, or nothing.
installed_pkg() {
  local c
  for c in "$1-bin" "$1" "$1-git"; do
    if pacman -Qq "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  pacman -Qqo "/usr/bin/$1" 2>/dev/null
}

# First existing .svg in directory $1 for the space-separated names in $2,
# or nothing.
find_icon() {
  local dir="$1" n
  [[ -n "$dir" ]] || return 1
  for n in $2; do
    if [[ -f "$dir/$n.svg" ]]; then echo "$dir/$n.svg"; return 0; fi
  done
  return 1
}

# True if the repo has an icon for the names in $1 that ICON_DIR lacks or has
# another version of, i.e. one that still has to be copied there.
icon_pending() {
  local repo
  repo="$(find_icon "$REPO_ICONS" "$1")" && ! cmp -s "$repo" "$ICON_DIR/${repo##*/}"
}

# Turn "1-2", "1,2-3", "all" into CHOSEN[0..N-1]=1. Returns 1 if invalid.
parse_selection() {
  local input="${1,,}" part a b i
  input="${input//[[:space:]]/}"
  CHOSEN=()
  [[ -n "$input" ]] || return 1
  if [[ "$input" == "all" ]]; then
    for ((i = 0; i < N; i++)); do CHOSEN[i]=1; done
    return 0
  fi
  local parts
  IFS=',' read -ra parts <<<"$input"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)$ ]]; then
      a=$((10#${BASH_REMATCH[1]})); b=$a
    elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    else
      return 1
    fi
    ((a >= 1 && b <= N && a <= b)) || return 1
    for ((i = a; i <= b; i++)); do CHOSEN[i - 1]=1; done
  done
  return 0
}

# Write the renamed launcher entries for app $1 (name $2, icon names $3,
# "nvidia" in $4 to start it on the NVIDIA GPU).
update_launcher() {
  local app="$1" name="$2" icons="$3" gpu="${4:-}" pkg icon="" run="" repo src dst found=0
  pkg="$(installed_pkg "$app")"
  # prime-run makes the NVIDIA GPU the only one the app can render on. It is
  # the entry that starts it that way, so this holds from the launcher and
  # for files opened with the app, and no other app is affected.
  if [[ $gpu == nvidia ]]; then
    if command -v prime-run >/dev/null 2>&1; then
      run="prime-run "
    else
      echo "   prime-run not found (package nvidia-prime); the app picks its GPU itself" >&2
    fi
  fi
  # The repo's icon wins and is copied into ICON_DIR if it is new or changed.
  # Without one, whatever ICON_DIR already has is used.
  if repo="$(find_icon "$REPO_ICONS" "$icons")"; then
    icon="$ICON_DIR/${repo##*/}"
    if icon_pending "$icons"; then
      if sudo install -Dm644 "$repo" "$icon"; then
        echo "   icon: ${repo##*/} copied to $ICON_DIR"
      else
        echo "   icon: could not copy ${repo##*/} to $ICON_DIR" >&2
      fi
    fi
    [[ -f "$icon" ]] || icon=""
  fi
  [[ -n "$icon" ]] || icon="$(find_icon "$ICON_DIR" "$icons")" || icon=""
  mkdir -p "$USER_APPS"
  while IFS= read -r src; do
    [[ -f "$src" ]] || continue
    found=1
    dst="$USER_APPS/$(basename "$src")"
    # Only the main [Desktop Entry] group is changed; action groups keep
    # their own names. Translated Name[xx]= lines are dropped so the new
    # name shows in every language. Every Exec line gets prime-run, the
    # ones of the actions too.
    awk -v name="$name" -v icon="$icon" -v run="$run" '
      /^\[/ { grp = $0 }
      grp == "[Desktop Entry]" && /^Name=/    { print "Name=" name; next }
      grp == "[Desktop Entry]" && /^Name\[/   { next }
      grp == "[Desktop Entry]" && icon != "" && /^Icon=/ { print "Icon=" icon; next }
      run != "" && /^Exec=/ { sub(/^Exec=/, "Exec=" run) }
      { print }
    ' "$src" >"$dst.tmp" && mv "$dst.tmp" "$dst"
    if [[ -n "$icon" ]]; then
      echo "   launcher: $name, icon $(basename "$icon")  ->  $dst"
    else
      echo "   launcher: $name, icon unchanged (no ${icons%% *}.svg in icons/ or $ICON_DIR)  ->  $dst"
    fi
    [[ -z "$run" ]] || echo "   launcher: starts on the NVIDIA GPU (prime-run)"
  done < <(pacman -Qlq "$pkg" 2>/dev/null | grep -E '^/usr/share/applications/[^/]+\.desktop$')
  if ((found == 0)); then
    echo "   no .desktop file found in package $pkg; launcher not changed" >&2
    return 1
  fi
}

# Uninstall app $1 and delete its launcher entries from USER_APPS. Nothing in
# ICON_DIR is touched.
remove_app() {
  local app="$1" pkg entry
  pkg="$(installed_pkg "$app")"
  if [[ -n "$pkg" ]]; then
    echo "   removing $pkg ..."
    # -s also removes its dependencies that nothing else uses, -n its config
    # files. stdin from /dev/null for the same reason as the install.
    if ! sudo pacman -Rns --noconfirm "$pkg" </dev/null || [[ -n "$(installed_pkg "$app")" ]]; then
      echo "   removal of $pkg failed" >&2
      return 1
    fi
  else
    echo "   not installed, nothing to uninstall"
  fi
  # Every entry in USER_APPS that starts this app. Found by its Exec line, so
  # an entry left behind by an app that was uninstalled by hand goes too.
  while IFS= read -r entry; do
    rm -f "$entry" && echo "   launcher entry removed: $entry"
  done < <(grep -lE "^Exec=(prime-run )?(/usr/bin/)?$app( |\$)" "$USER_APPS"/*.desktop 2>/dev/null)
  return 0
}

# ---- menu -------------------------------------------------------------------
echo "Craft apps:"
for ((i = 0; i < N; i++)); do
  IFS='|' read -r app name icons gpu <<<"${APPS[i]}"
  if [[ -n "$(installed_pkg "$app")" ]]; then state="installed"; else state="not installed"; fi
  printf "  %d) %-11s -> %-12s [%s]\n" "$((i + 1))" "$app" "$name" "$state"
done
echo

CHOSEN=()
if (($# > 0)); then
  if ! parse_selection "$*"; then
    echo "Invalid selection '$*'. Use e.g. 1-2, 1,2-3, 4 or all (1-$N)." >&2
    exit 1
  fi
else
  question="Which ones?"
  [[ $MODE == remove ]] && question="Which ones to REMOVE?"
  while :; do
    read -rp "$question (e.g. 1-2, 1,2-3, all): " answer || { echo; exit 1; }
    parse_selection "$answer" && break
    echo "  Not valid. Use numbers 1-$N, ranges like 2-4, commas, or all."
  done
fi

# ---- sudo -------------------------------------------------------------------
# Only when a chosen app still has to be installed, its icon still has to be
# copied into ICON_DIR, or (when removing) it is installed. One prompt up
# front; the keepalive outlasts sudo's 15-minute timeout, so yay never stops
# to ask.
need_sudo=0
for ((i = 0; i < N; i++)); do
  [[ -n "${CHOSEN[i]:-}" ]] || continue
  IFS='|' read -r app name icons gpu <<<"${APPS[i]}"
  if [[ $MODE == remove ]]; then
    [[ -z "$(installed_pkg "$app")" ]] || need_sudo=1
  elif [[ -z "$(installed_pkg "$app")" ]]; then
    # Without yay the install fails before anything needs root.
    ! command -v yay >/dev/null 2>&1 || need_sudo=1
  elif icon_pending "$icons"; then
    need_sudo=1
  fi
done
if ((need_sudo)); then
  if ! sudo -v; then
    echo "sudo authentication failed; nothing was installed or changed." >&2
    exit 1
  fi
  ( while kill -0 "$$" 2>/dev/null; do sleep 60; sudo -n -v; done ) 2>/dev/null &
  SUDO_KEEPALIVE=$!
  trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT
fi

# ---- install + rename, or remove --------------------------------------------
ok=() failed=()
for ((i = 0; i < N; i++)); do
  [[ -n "${CHOSEN[i]:-}" ]] || continue
  IFS='|' read -r app name icons gpu <<<"${APPS[i]}"
  echo
  echo "== $app ($name)"
  if [[ $MODE == remove ]]; then
    if remove_app "$app"; then ok+=("$app"); else failed+=("$app"); fi
    continue
  fi
  if [[ -n "$(installed_pkg "$app")" ]]; then
    echo "   already installed ($(installed_pkg "$app")), skipping install"
  else
    if ! command -v yay >/dev/null 2>&1; then
      echo "   yay not found; cannot install $app-bin" >&2
      failed+=("$app"); continue
    fi
    echo "   installing $app-bin ..."
    # --noconfirm answers every yay and pacman question with its default.
    # stdin from /dev/null: a question that slips through fails the install
    # instead of blocking the run.
    if ! yay -S --noconfirm --needed "$app-bin" </dev/null || [[ -z "$(installed_pkg "$app")" ]]; then
      echo "   install of $app-bin failed" >&2
      failed+=("$app"); continue
    fi
  fi
  if update_launcher "$app" "$name" "$icons" "$gpu"; then ok+=("$app"); else failed+=("$app"); fi
done

if command -v update-desktop-database >/dev/null 2>&1 && [[ -d "$USER_APPS" ]]; then
  update-desktop-database "$USER_APPS" >/dev/null 2>&1 || true
fi

echo
if [[ $MODE == remove ]]; then
  echo "Removed: ${ok[*]:-none}"
else
  echo "Done: ${ok[*]:-none}"
fi
if ((${#failed[@]} > 0)); then
  echo "Failed: ${failed[*]}"
  exit 1
fi
