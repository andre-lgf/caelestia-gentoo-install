#!/usr/bin/env bash
# Install the Caelestia SDDM theme (https://github.com/ItsABigIgloo/caelestia-sddm) on Gentoo
# and enable SDDM. A Gentoo port of the upstream scripts/install.sh (which needs pacman).
#
#   ./install-sddm-theme.sh [locklike|minimalist|minimalistV2]   (default: prompt, locklike)
#
# Run it from inside Hyprland, as your normal user. Re-run to switch theme or update.

set -euo pipefail

REPO=https://github.com/ItsABigIgloo/caelestia-sddm.git
COMMIT=dd69abbb7eb122546cbabe84e116ba03e67a4ccc   # 2026-10-01

SRC_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-gentoo/src/caelestia-sddm
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
THEME_DIR=/usr/share/sddm/themes/caelestia
SYNC=$THEME_DIR/scripts/sync.sh
SUDOERS=/etc/sudoers.d/caelestia-sddm-sync

c_info=$'\e[1;36m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
log()  { printf '%s::%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
ask()  { local r; read -r -p "$1 [y/N] " r; [[ $r == [yY]* ]]; }

# ---------------------------------------------------------------- checks
[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it uses sudo)."
command -v sddm >/dev/null || die "sddm is not installed (emerge x11-misc/sddm)."
command -v caelestia >/dev/null || die "caelestia CLI not found; run ./install-caelestia.sh first."
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || warn "Not running inside Hyprland; regenerating the colour scheme may fail."

sudo -v

# ---------------------------------------------------------------- dependencies
# qt5compat: Qt5Compat.GraphicalEffects, qtmultimedia: video wallpapers,
# roboto: one of the theme fonts (Rubik, Material Symbols, CaskaydiaCove are already installed),
# qtimageformats: webp wallpapers (the default Caelestia wallpaper is webp).
log "Installing dependencies"
# qtmultimedia[qml] -> qtquick3d -> assimp -> virtual/minizip needs this
echo 'sys-libs/zlib minizip' | sudo tee /etc/portage/package.use/caelestia-gentoo-sddm >/dev/null
sudo emerge --ask=n --noreplace --verbose \
    dev-qt/qtsvg dev-qt/qt5compat dev-qt/qtmultimedia dev-qt/qtimageformats media-fonts/roboto

# ---------------------------------------------------------------- source
log "Fetching caelestia-sddm @ ${COMMIT:0:7}"
if [[ -d $SRC_DIR/.git ]]; then
    git -C "$SRC_DIR" fetch -q origin
else
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone -q "$REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" checkout -q --force "$COMMIT"
git -C "$SRC_DIR" clean -qfdx

# ---------------------------------------------------------------- theme choice
mapfile -t THEMES < <(find "$SRC_DIR/themes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
THEME=${1:-}
if [[ -z $THEME ]]; then
    echo "Available themes:"
    for i in "${!THEMES[@]}"; do echo "  $((i + 1))) ${THEMES[i]}"; done
    read -r -p "Select theme [locklike]: " sel
    if [[ -z $sel ]]; then THEME=locklike
    elif [[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#THEMES[@]})); then THEME=${THEMES[sel - 1]}
    else THEME=$sel
    fi
fi
SRC_THEME=$SRC_DIR/themes/$THEME
[[ -d $SRC_THEME ]] || die "unknown theme '$THEME' (available: ${THEMES[*]})"
! find "$SRC_THEME" -type l -print -quit | grep -q . || die "theme contains symlinks, refusing to install."

# ---------------------------------------------------------------- install theme
log "Installing theme '$THEME' to $THEME_DIR"
sudo rm -rf "$THEME_DIR" /var/lib/sddm/.cache/sddm-greeter-qt6
sudo install -d -m 755 "$THEME_DIR/scripts"
sudo cp -r "$SRC_THEME"/. "$THEME_DIR/"
sudo install -m 755 "$SRC_DIR/scripts/sync.sh" "$SYNC"
sudo find "$THEME_DIR" -type d -exec chmod 755 {} +
sudo find "$THEME_DIR" -type f ! -path "$SYNC" -exec chmod 644 {} +

# Colour template, rendered by `caelestia scheme set` into ~/.local/state/caelestia/theme/
TEMPLATE=$CONFIG/caelestia/templates/sddm-theme.conf
mkdir -p "$(dirname "$TEMPLATE")"
if [[ -f $TEMPLATE ]] && ! cmp -s "$TEMPLATE" "$SRC_THEME/theme.conf.template"; then
    cp "$TEMPLATE" "$TEMPLATE.bak"
    warn "Your old $TEMPLATE was saved as $TEMPLATE.bak"
fi
cp "$SRC_THEME/theme.conf.template" "$TEMPLATE"

# SDDM drop-in (sorts after Gentoo's 01gentoo.conf, which keeps the X11 greeter)
log "Writing /etc/sddm.conf.d/caelestia.conf"
sudo tee /etc/sddm.conf.d/caelestia.conf >/dev/null <<'EOF'
[General]
GreeterEnvironment=QML_XHR_ALLOW_FILE_READ=1,QT_QPA_PLATFORM=xcb

[Theme]
Current=caelestia
EOF

# ---------------------------------------------------------------- first sync
# Regenerate the scheme here (in the session, as you) so the template gets rendered,
# then copy colours/wallpaper/avatar into the theme.
log "Rendering colours and syncing wallpaper"
mapfile -t scheme < <(caelestia scheme get --name --mode --variant)
if ((${#scheme[@]} == 3)); then
    caelestia scheme set --name "${scheme[0]}" --mode "${scheme[1]}" --variant "${scheme[2]}" \
        || warn "caelestia scheme set failed; colours may be stale until the next scheme change."
else
    warn "couldn't read the current scheme; colours will update on the next scheme change."
fi
sudo "$SYNC" --posthook

# ---------------------------------------------------------------- auto sync (optional)
echo
if ask "Keep the login screen in sync automatically when you change wallpaper/scheme? (adds a NOPASSWD sudoers rule for $SYNC only)"; then
    sudo install -d -m 750 /etc/sudoers.d
    tmp=$(mktemp)
    echo "$USER ALL=(root) NOPASSWD: $SYNC" >"$tmp"
    if sudo visudo -cf "$tmp" >/dev/null; then
        sudo install -m 440 -o root -g root "$tmp" "$SUDOERS"
    else
        warn "sudoers rule failed validation, skipped."
    fi
    rm -f "$tmp"
    sudo grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
        || warn "/etc/sudoers doesn't include /etc/sudoers.d; add '@includedir /etc/sudoers.d' with visudo."

    # Add the posthooks to cli.json, keeping everything else
    python3 -I - "$CONFIG/caelestia/cli.json" "sudo -n $SYNC --posthook" <<'EOF'
import json, sys, pathlib
path, hook = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = json.loads(path.read_text()) if path.exists() else {}
for key in ("wallpaper", "theme"):
    sect = cfg.setdefault(key, {})
    old = sect.get("postHook")
    if old and old != hook:
        print(f"!! {key}.postHook was {old!r}, replaced (old value saved in {path}.bak)", file=sys.stderr)
        path.with_suffix(".json.bak").write_text(path.read_text())
    sect["postHook"] = hook
path.write_text(json.dumps(cfg, indent=4) + "\n")
EOF
    log "Added wallpaper/theme postHooks to $CONFIG/caelestia/cli.json"
else
    log "Skipped. Sync manually after changing wallpaper/scheme with: sudo $SYNC"
fi

# ---------------------------------------------------------------- enable sddm
echo
if [[ $(systemctl is-enabled sddm 2>/dev/null) == enabled ]]; then
    log "SDDM is already enabled."
elif ask "Enable SDDM as your login screen now (takes effect on next boot)?"; then
    sudo systemctl enable sddm
fi

echo
log "Done. Preview without logging out:"
log "    QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=xcb sddm-greeter-qt6 --test-mode --theme $THEME_DIR"
log "Avatar: put an image at ~/.face (or ~/.face.icon) and run: sudo $SYNC"
log "Options (clock format, blur...): edit $TEMPLATE, then change scheme or run: sudo $SYNC"
log "If SDDM won't start: Ctrl+Alt+F2, log in, sudo systemctl disable sddm, reboot."
