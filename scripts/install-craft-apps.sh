#!/usr/bin/env bash
# Install Craft apps from the AUR (-bin packages) and rename their launcher
# entries (Photoshop, Premiere Pro, Word, Excel, PowerPoint).
#
# Usage:  ./install-craft-apps.sh            # asks which apps
#         ./install-craft-apps.sh 1,3-5      # or: 1-2 | 2 | all
#
# - Nothing is asked after the selection. If something has to be installed,
#   sudo asks for the password once, right away; from then on yay runs with
#   --noconfirm and a keepalive stops sudo from asking again.
# - An app that is already installed is not reinstalled; only its launcher
#   entry is updated.
# - The launcher entry is written to ~/.local/share/applications, which
#   overrides the packaged one in /usr/share/applications and survives
#   package updates. Delete the file there to get the original entry back.
# - The icon is switched only if the matching .svg exists in ICON_DIR;
#   otherwise only the name changes.

set -u

ICON_DIR=/usr/share/icons/hicolor/scalable/apps
USER_APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

# app (binary / base package name) | launcher name | icon file names to try
APPS=(
  "photocraft|Photoshop|photoshop"
  "filmcraft|Premiere Pro|premiere premiere-pro premierepro premiere_pro"
  "wordcraft|Word|word"
  "gridcraft|Excel|excel"
  "deckcraft|PowerPoint|powerpoint"
)
N=${#APPS[@]}

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root (yay asks for sudo itself)." >&2
  exit 1
fi

# Name of the installed package that provides app $1, or nothing.
installed_pkg() {
  local c
  for c in "$1-bin" "$1" "$1-git"; do
    if pacman -Qq "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  pacman -Qqo "/usr/bin/$1" 2>/dev/null
}

# First existing icon for the space-separated names in $1, or nothing.
find_icon() {
  local n
  for n in $1; do
    if [[ -f "$ICON_DIR/$n.svg" ]]; then echo "$ICON_DIR/$n.svg"; return 0; fi
  done
  return 1
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

# Write the renamed launcher entries for app $1 (name $2, icon names $3).
update_launcher() {
  local app="$1" name="$2" icons="$3" pkg icon src dst found=0
  pkg="$(installed_pkg "$app")"
  icon="$(find_icon "$icons")" || icon=""
  mkdir -p "$USER_APPS"
  while IFS= read -r src; do
    [[ -f "$src" ]] || continue
    found=1
    dst="$USER_APPS/$(basename "$src")"
    # Only the main [Desktop Entry] group is changed; action groups keep
    # their own names. Translated Name[xx]= lines are dropped so the new
    # name shows in every language.
    awk -v name="$name" -v icon="$icon" '
      /^\[/ { grp = $0 }
      grp == "[Desktop Entry]" && /^Name=/    { print "Name=" name; next }
      grp == "[Desktop Entry]" && /^Name\[/   { next }
      grp == "[Desktop Entry]" && icon != "" && /^Icon=/ { print "Icon=" icon; next }
      { print }
    ' "$src" >"$dst.tmp" && mv "$dst.tmp" "$dst"
    if [[ -n "$icon" ]]; then
      echo "   launcher: $name, icon $(basename "$icon")  ->  $dst"
    else
      echo "   launcher: $name, icon unchanged (no ${icons%% *}.svg in $ICON_DIR)  ->  $dst"
    fi
  done < <(pacman -Qlq "$pkg" 2>/dev/null | grep -E '^/usr/share/applications/[^/]+\.desktop$')
  if ((found == 0)); then
    echo "   no .desktop file found in package $pkg; launcher not changed" >&2
    return 1
  fi
}

# ---- menu -------------------------------------------------------------------
echo "Craft apps:"
for ((i = 0; i < N; i++)); do
  IFS='|' read -r app name icons <<<"${APPS[i]}"
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
  while :; do
    read -rp "Which ones? (e.g. 1-2, 1,2-3, all): " answer || { echo; exit 1; }
    parse_selection "$answer" && break
    echo "  Not valid. Use numbers 1-$N, ranges like 2-4, commas, or all."
  done
fi

# ---- sudo -------------------------------------------------------------------
# Only when a chosen app still has to be installed. One prompt up front; the
# keepalive outlasts sudo's 15-minute timeout, so yay never stops to ask.
need_install=0
for ((i = 0; i < N; i++)); do
  [[ -n "${CHOSEN[i]:-}" ]] || continue
  IFS='|' read -r app name icons <<<"${APPS[i]}"
  [[ -n "$(installed_pkg "$app")" ]] || need_install=1
done
if ((need_install)) && command -v yay >/dev/null 2>&1; then
  if ! sudo -v; then
    echo "sudo authentication failed; nothing was installed or changed." >&2
    exit 1
  fi
  ( while kill -0 "$$" 2>/dev/null; do sleep 60; sudo -n -v; done ) 2>/dev/null &
  SUDO_KEEPALIVE=$!
  trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT
fi

# ---- install + rename -------------------------------------------------------
ok=() failed=()
for ((i = 0; i < N; i++)); do
  [[ -n "${CHOSEN[i]:-}" ]] || continue
  IFS='|' read -r app name icons <<<"${APPS[i]}"
  echo
  echo "== $app ($name)"
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
  if update_launcher "$app" "$name" "$icons"; then ok+=("$app"); else failed+=("$app"); fi
done

if command -v update-desktop-database >/dev/null 2>&1 && [[ -d "$USER_APPS" ]]; then
  update-desktop-database "$USER_APPS" >/dev/null 2>&1 || true
fi

echo
echo "Done: ${ok[*]:-none}"
if ((${#failed[@]} > 0)); then
  echo "Failed: ${failed[*]}"
  exit 1
fi
