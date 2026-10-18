#!/usr/bin/env bash
# Install caelestia-shell, caelestia-cli and the Caelestia dotfiles on Gentoo.
# Run ./install-deps.sh first.
#
#   ./install-caelestia.sh [extra args for `caelestia install`]
#   e.g. ./install-caelestia.sh --enable-components nvim,uwsm
#
# Best run from a terminal inside Hyprland, so the post-install hooks
# (hyprctl reload, starting the shell) can run.
#
# Re-run to update the shell/CLI to the versions pinned below.

set -euo pipefail

SHELL_TAG=v2.5.0
CLI_TAG=v1.1.3
# The firefox component is skipped (Brave is used instead).
DISABLE_COMPONENTS=firefox

SRC_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-gentoo/src
CLI_VENV=/opt/caelestia-cli
MANIFEST_DIR=/usr/local/share/caelestia-gentoo/manifests
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}

c_info=$'\e[1;36m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
log()  { printf '%s::%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

# Clone (or update) a repo at a tag.
checkout() {  # checkout url dir tag
    if [[ -d $2/.git ]]; then
        git -C "$2" fetch -q --depth 1 origin "refs/tags/$3:refs/tags/$3"
        git -C "$2" checkout -q --force "$3"
        git -C "$2" clean -qfdx
    else
        mkdir -p "$(dirname "$2")"
        git clone -q --depth 1 --branch "$3" "$1" "$2"
    fi
}

# Install a staged DESTDIR into /, removing files from the previous install first.
install_staged() {  # install_staged name stagedir
    local name=$1 stage=$2 manifest="$MANIFEST_DIR/$1.txt"
    if [[ -f $manifest ]]; then
        while IFS= read -r f; do
            [[ -n $f && $f == /* ]] && sudo rm -f -- "$f"
        done <"$manifest"
    fi
    sudo mkdir -p "$MANIFEST_DIR"
    (cd "$stage" && find . \( -type f -o -type l \) | sed 's|^\.||' | sort) | sudo tee "$manifest" >/dev/null
    # --no-overwrite-dir: never touch the mode/owner of existing dirs like / or /usr
    tar -C "$stage" -cf - . | sudo tar -C / -xf - --no-same-owner --no-overwrite-dir
}

# ---------------------------------------------------------------- checks
[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it uses sudo)."

missing=()
command -v qs >/dev/null || missing+=("quickshell")
[[ -f /usr/lib64/qt6/qml/M3Shapes/qmldir ]] || missing+=("m3shapes")
PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH} pkg-config --exists libcava || missing+=("libcava")
python3 -c 'import materialyoucolor, PIL' 2>/dev/null || missing+=("materialyoucolor/pillow")
python3 -c 'import build, installer, hatchling, hatch_vcs' 2>/dev/null || missing+=("python build tools")
command -v fish >/dev/null || missing+=("fish")
((${#missing[@]} == 0)) || die "missing dependencies: ${missing[*]}. Run ./install-deps.sh first."

if ! portageq has_version / '=gui-apps/quickshell-9999' 2>/dev/null; then
    warn "quickshell does not look like the git (9999) version; the shell requires quickshell-git."
fi

in_hyprland=false
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && in_hyprland=true
$in_hyprland || warn "Not running inside Hyprland: post-install hooks (hyprctl reload, starting the shell) will fail. That's OK, see the notes at the end."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/caelestia-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

sudo -v

# ---------------------------------------------------------------- backup
BACKUP="$HOME/caelestia-config-backup-$(date +%Y%m%d-%H%M%S)"
log "Backing up configs that the dots will overwrite to $BACKUP"
mkdir -p "$BACKUP"
for p in hypr fish foot fastfetch btop micro Thunar starship.toml caelestia uwsm; do
    [[ -e $CONFIG/$p ]] && cp -a "$CONFIG/$p" "$BACKUP/"
done
rmdir "$BACKUP" 2>/dev/null && log "(nothing to back up)" || true

# ---------------------------------------------------------------- shell
log "Building caelestia-shell $SHELL_TAG"
checkout https://github.com/caelestia-dots/shell.git "$SRC_DIR/shell" "$SHELL_TAG"
PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH} \
cmake -S "$SRC_DIR/shell" -B "$WORK/shell-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DVERSION="${SHELL_TAG#v}" \
    -DGIT_REVISION="$(git -C "$SRC_DIR/shell" rev-parse HEAD)" \
    -DDISTRIBUTOR="Gentoo (caelestia-gentoo)" \
    -DINSTALL_LIBDIR=usr/lib/caelestia \
    -DINSTALL_QMLDIR=usr/lib64/qt6/qml \
    -DINSTALL_QSCONFDIR=etc/xdg/quickshell/caelestia
cmake --build "$WORK/shell-build"
DESTDIR="$WORK/stage-shell" cmake --install "$WORK/shell-build"
log "Installing caelestia-shell"
install_staged caelestia-shell "$WORK/stage-shell"

# ---------------------------------------------------------------- cli
log "Building caelestia-cli $CLI_TAG"
checkout https://github.com/caelestia-dots/cli.git "$SRC_DIR/cli" "$CLI_TAG"
# Fix: the recorder inherits the caller's stdout/stderr. When started from the shell's
# panel, that's a pipe the shell closes once `caelestia record` exits, so the recorder
# dies of SIGPIPE ~1s in (empty recording, panel resets). Detach it from those pipes.
sed -i 's|proc = subprocess.Popen(\[RECORDER, \*args, "-o", str(recording_path)\], start_new_session=True)|proc = subprocess.Popen([RECORDER, *args, "-o", str(recording_path)], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)|' \
    "$SRC_DIR/cli/src/caelestia/subcommands/record.py"
grep -q 'stderr=subprocess.DEVNULL)' "$SRC_DIR/cli/src/caelestia/subcommands/record.py" \
    || warn "couldn't apply the recorder SIGPIPE fix (record.py changed upstream?)"
python3 -m build --wheel --no-isolation --outdir "$WORK/dist" "$SRC_DIR/cli"

log "Installing caelestia-cli into $CLI_VENV (venv using the system's pillow/materialyoucolor)"
sudo rm -rf "$CLI_VENV"
sudo python3 -m venv --system-site-packages --without-pip "$CLI_VENV"
sudo "$CLI_VENV/bin/python" -m installer "$WORK"/dist/*.whl

mkdir -p "$WORK/stage-cli/usr/local/bin" "$WORK/stage-cli/usr/local/share/fish/vendor_completions.d"
ln -s "$CLI_VENV/bin/caelestia" "$WORK/stage-cli/usr/local/bin/caelestia"
install -m644 "$SRC_DIR/cli/completions/caelestia.fish" "$WORK/stage-cli/usr/local/share/fish/vendor_completions.d/caelestia.fish"
install_staged caelestia-cli "$WORK/stage-cli"
hash -r
caelestia -h >/dev/null || die "the caelestia command does not run"

# ---------------------------------------------------------------- user overrides
# Picked up by the dots' hyprland.lua; only created if you don't have one yet.
if [[ ! -f $CONFIG/caelestia/hypr-vars.lua ]]; then
    log "Creating $CONFIG/caelestia/hypr-vars.lua (Brave, pavucontrol, Bibata cursors)"
    mkdir -p "$CONFIG/caelestia"
    cursor=""
    [[ -d /usr/share/icons/Bibata-Modern-Classic ]] && cursor='    cursorTheme = "Bibata-Modern-Classic",'
    cat >"$CONFIG/caelestia/hypr-vars.lua" <<EOF
-- Overrides for the variables in ~/.config/hypr/variables.lua
return {
    browser = "brave-browser-stable",
    audioSettings = "pavucontrol",
$cursor
}
EOF
fi

# Shell config: options left out keep their defaults.
if [[ ! -f $CONFIG/caelestia/shell.json ]]; then
    log "Creating $CONFIG/caelestia/shell.json (pavucontrol as audio app)"
    mkdir -p "$CONFIG/caelestia"
    cat >"$CONFIG/caelestia/shell.json" <<'EOF'
{
    "general": {
        "apps": {
            "audio": ["pavucontrol"]
        }
    }
}
EOF
else
    warn "$CONFIG/caelestia/shell.json exists; set general.apps.audio to [\"pavucontrol\"] there yourself."
fi

# ---------------------------------------------------------------- dots
echo
log "Running \`caelestia install\` (it skips package installation on non-Arch systems)"
caelestia install --disable-components "$DISABLE_COMPONENTS" "$@"

# ---------------------------------------------------------------- done
echo
log "Done."
log "  Shell:   /etc/xdg/quickshell/caelestia (+ QML plugin in /usr/lib64/qt6/qml/Caelestia)"
log "  CLI:     /usr/local/bin/caelestia -> $CLI_VENV"
log "  Dots:    ~/.local/state/caelestia/dots (managed by the CLI)"
[[ -d $BACKUP ]] && log "  Backup:  $BACKUP"
log "  Personal Hyprland tweaks go in $CONFIG/caelestia/hypr-user.lua"
if ! $in_hyprland; then
    log "Since this ran outside Hyprland, after logging into Hyprland run:"
    log "    caelestia scheme set -n caelestia   (only if no scheme was set)"
    log "    hyprctl reload"
fi
log "\`caelestia update\` updates the dots only (it skips system packages off Arch)."
log "To update the shell/CLI, bump SHELL_TAG/CLI_TAG in this script and re-run it."
