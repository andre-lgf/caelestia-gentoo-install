#!/usr/bin/env bash
# Install the dependencies of the Caelestia shell, CLI and dotfiles on Gentoo.
#
# Mirrors the Arch packages from:
#   - caelestia-dots/shell  (caelestia-shell PKGBUILD / README)
#   - caelestia-dots/cli    (caelestia-cli PKGBUILD / README)
#   - caelestia-dots/caelestia manifest.toml (all default components except firefox)
#
# Packages that exist in ::gentoo / ::guru / ::hyproverlay are emerged.
# Packages with no Gentoo equivalent are built/installed from pinned sources:
#   m3shapes, Material Symbols + Rubik fonts, dart-sass, papirus-folders
# Every file installed from source is recorded in /usr/local/share/caelestia-gentoo/manifests/.
#
# Run as your normal user (it calls sudo). Re-running is safe.

set -euo pipefail

# ---------------------------------------------------------------- pinned sources
M3SHAPES_COMMIT=8a6fe8961749887d677700b6508e0c9249968b7e
MSYMBOLS_COMMIT=49d4db35df873165d6bd6ba09b063c7dafbac2f4
MSYMBOLS_ROUNDED_SHA256=32e4011709e055596eb8d2dd0f7cb547b47c1d40ac9ecb8fad54f7f7eac202e7
MSYMBOLS_OUTLINED_SHA256=77ff1c20896afc6f1abf7d57fc408234dfd021ab050b63e0442e71d6c9f0d6b8
MSYMBOLS_SHARP_SHA256=d0738765ddc91294f1959a6d23ceb2980947f1d1dbe810226387c9240130fa03
RUBIK_COMMIT=e337a5f69a9bea30e58d05bd40184d79cc099628
RUBIK_SHA256=1b3a7437ba2af80e465e773ed60c5036d1ba6ace492d89046dbcf18fb31e4e88
RUBIK_ITALIC_SHA256=08c6c4018a5ada8b517407b46897e46cf6ebb106853fbd3e89addb51d3b59c62
DART_SASS_VER=1.105.2
DART_SASS_SHA256=a530ee08d5792c80bdb9d9614b45fb58219c890cb42a280a80775f0af9c29582
PAPIRUS_FOLDERS_VER=1.14.0
PAPIRUS_FOLDERS_SHA256=658723db46638ad988ef91ed7d28e9941b528418f7c83d51fe17cdf4985e6dd2

MANIFEST_DIR=/usr/local/share/caelestia-gentoo/manifests
FONT_DIR=/usr/local/share/fonts/caelestia

# ---------------------------------------------------------------- packages
PACKAGES=(
    # --- caelestia-shell runtime ---
    gui-apps/quickshell              # kept as installed; see the 9999 prompt below
    app-misc/ddcutil
    app-misc/brightnessctl
    sys-apps/lm-sensors
    media-libs/aubio
    media-sound/libcava              # ::guru, the LukashonakV/cava shared-library fork
    media-video/pipewire
    sci-libs/libqalculate
    sys-power/power-profiles-daemon
    net-misc/networkmanager
    dev-qt/qtbase
    dev-qt/qtdeclarative
    dev-qt/qtimageformats
    dev-qt/qtsvg
    gui-apps/swappy
    app-shells/fish
    media-fonts/nerdfonts            # USE=cascadiacode jetbrainsmono (set below)

    # --- build deps (shell, m3shapes, cli) ---
    dev-build/cmake
    dev-build/ninja
    dev-qt/qtshadertools
    dev-util/pkgconf
    dev-vcs/git
    dev-python/build
    dev-python/installer
    dev-python/hatchling
    dev-python/hatch-vcs

    # --- caelestia-cli runtime ---
    dev-python/pillow
    dev-python/materialyoucolor
    x11-libs/libnotify
    gui-apps/grim
    gui-apps/slurp
    gui-apps/wl-clipboard
    media-video/gpu-screen-recorder
    dev-libs/glib
    gnome-base/dconf
    app-misc/cliphist
    gui-apps/fuzzel
    sys-process/psmisc               # killall

    # --- dots: hypr ---
    gui-libs/xdg-desktop-portal-hyprland
    sys-apps/xdg-desktop-portal-gtk
    # --- dots: fish ---
    sys-apps/eza
    app-shells/zoxide
    app-shells/direnv
    # --- dots: foot, fastfetch, btop, micro, thunar, starship ---
    gui-apps/foot
    app-misc/fastfetch
    sys-process/btop
    app-editors/micro
    xfce-base/thunar
    app-shells/starship
    # --- dots: gtk ---
    x11-themes/adw-gtk3
    x11-themes/papirus-icon-theme
    # --- dots: auth ---
    gnome-base/gnome-keyring
    gnome-extra/polkit-gnome
    # --- dots: bluetooth (bluez includes Arch's bluez-utils) ---
    net-wireless/bluez
    # --- dots: pipewire ---
    media-video/wireplumber
    media-sound/pavucontrol          # instead of pwvucontrol (set up by install-caelestia.sh)
    # --- dots: fonts ---
    media-fonts/noto
    media-fonts/noto-cjk
    media-fonts/noto-emoji
    # --- dots: tools ---
    net-misc/curl
    app-misc/jq
    app-misc/trash-cli
    dev-vcs/lazygit
    sys-apps/bat
    sys-apps/ripgrep
    x11-misc/ydotool
    gui-apps/hyprpicker
    x11-misc/xdg-user-dirs
    # --- started by the hypr config (execs.lua) ---
    app-misc/geoclue
    x11-misc/gammastep
    x11-themes/bibata-xcursors       # replacement for the AUR-only sweet-cursors
)

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;36m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
log()  { printf '%s::%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

ask() {  # ask "question" [default y|n]
    local def=${2:-n} reply hint="[y/N]"
    [[ $def == y ]] && hint="[Y/n]"
    read -rp "$1 $hint " reply || true
    reply=${reply:-$def}
    [[ $reply =~ ^[Yy] ]]
}

fetch() {  # fetch url dest sha256
    curl -fL --retry 3 -o "$2" "$1"
    echo "$3  $2" | sha256sum -c --quiet - || die "checksum mismatch for $1"
}

# Records files installed under a staging DESTDIR, then copies them into /.
install_staged() {  # install_staged name stagedir
    local name=$1 stage=$2
    sudo mkdir -p "$MANIFEST_DIR"
    (cd "$stage" && find . \( -type f -o -type l \) | sed 's|^\.||' | sort) \
        | sudo tee "$MANIFEST_DIR/$name.txt" >/dev/null
    # --no-overwrite-dir: never touch the mode/owner of existing dirs like / or /usr
    tar -C "$stage" -cf - . | sudo tar -C / -xf - --no-same-owner --no-overwrite-dir
}

# ---------------------------------------------------------------- checks
[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it uses sudo)."
[[ -f /etc/gentoo-release ]] || die "this script is for Gentoo."
command -v sudo >/dev/null || die "sudo is required."

for repo in guru hyproverlay; do
    [[ -d /var/db/repos/$repo ]] || die "the ::$repo overlay is required: sudo eselect repository enable $repo && sudo emaint sync -r $repo"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/caelestia-deps.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

sudo -v

# ---------------------------------------------------------------- portage config
log "Writing /etc/portage/package.accept_keywords/caelestia-gentoo"
sudo mkdir -p /etc/portage/package.accept_keywords /etc/portage/package.use
sudo tee /etc/portage/package.accept_keywords/caelestia-gentoo >/dev/null <<'EOF'
# Managed by caelestia-gentoo/install-deps.sh
# Live ebuilds (no tagged release is new enough / exists)
dev-python/materialyoucolor **
# GURU / testing-only packages
app-editors/micro ~amd64
app-misc/brightnessctl ~amd64
app-misc/cliphist ~amd64
app-shells/direnv ~amd64
app-shells/zoxide ~amd64
gui-apps/fuzzel ~amd64
gui-apps/hyprpicker ~amd64
media-video/gpu-screen-recorder ~amd64
x11-themes/adw-gtk3 ~amd64
x11-themes/bibata-xcursors ~amd64
dev-vcs/lazygit ~amd64
media-fonts/nerdfonts ~amd64
media-sound/libcava ~amd64
EOF

log "Writing /etc/portage/package.use/caelestia-gentoo"
sudo tee /etc/portage/package.use/caelestia-gentoo >/dev/null <<'EOF'
# Managed by caelestia-gentoo/install-deps.sh
# ttf-cascadia-code-nerd (shell) + ttf-jetbrains-mono-nerd (hypr/foot)
media-fonts/nerdfonts cascadiacode jetbrainsmono
# the trash panel plugin pulls in the whole xfce4-panel
xfce-base/thunar -trash-panel-plugin
# gammastep runs headless from the hypr config; its GTK tray pulls in libdbusmenu/appindicator
x11-misc/gammastep -gtk
EOF

# ---------------------------------------------------------------- quickshell
# caelestia-shell upstream (and the AUR package) depend on quickshell-git. A tagged
# release may work; if the shell shows QML errors about unknown types/properties,
# re-run this script and answer yes here.
if ! portageq has_version / '=gui-apps/quickshell-9999' 2>/dev/null; then
    warn "caelestia-shell officially requires quickshell-git (gui-apps/quickshell-9999)."
    if ask "Switch quickshell to the live 9999 ebuild?" n; then
        echo 'gui-apps/quickshell **' | sudo tee /etc/portage/package.accept_keywords/caelestia-gentoo-quickshell >/dev/null
        PACKAGES=("${PACKAGES[@]/#gui-apps\/quickshell/=gui-apps\/quickshell-9999}")
    fi
fi

# ---------------------------------------------------------------- emerge
log "Emerging packages (portage will ask for confirmation)."
log "Any extra keyword/USE changes portage needs are written to /etc/portage automatically (--autounmask-continue)."
sudo emerge --ask --verbose --noreplace --autounmask-continue "${PACKAGES[@]}"

# ---------------------------------------------------------------- m3shapes
if [[ -f /usr/lib64/qt6/qml/M3Shapes/qmldir ]]; then
    log "m3shapes already installed, skipping"
else
    log "Building m3shapes ($M3SHAPES_COMMIT)"
    git clone -q https://github.com/soramanew/m3shapes "$WORK/m3shapes"
    git -C "$WORK/m3shapes" checkout -q "$M3SHAPES_COMMIT"
    cmake -S "$WORK/m3shapes" -B "$WORK/m3shapes/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib64 \
        -DINSTALL_QMLDIR=lib64/qt6/qml
    cmake --build "$WORK/m3shapes/build"
    DESTDIR="$WORK/stage-m3shapes" cmake --install "$WORK/m3shapes/build"
    install_staged m3shapes "$WORK/stage-m3shapes"
    sudo ldconfig
fi

# ---------------------------------------------------------------- fonts
log "Installing Material Symbols (variable) and Rubik (variable) fonts to $FONT_DIR"
mkdir -p "$WORK/stage-fonts$FONT_DIR"
ms_base="https://raw.githubusercontent.com/google/material-design-icons/$MSYMBOLS_COMMIT/variablefont"
for style in Rounded Outlined Sharp; do
    var="MSYMBOLS_${style^^}_SHA256"
    fetch "$ms_base/MaterialSymbols$style%5BFILL,GRAD,opsz,wght%5D.ttf" \
        "$WORK/stage-fonts$FONT_DIR/MaterialSymbols${style}[FILL,GRAD,opsz,wght].ttf" "${!var}"
done
rubik_base="https://github.com/googlefonts/rubik/raw/$RUBIK_COMMIT/fonts/variable"
fetch "$rubik_base/Rubik%5Bwght%5D.ttf" "$WORK/stage-fonts$FONT_DIR/Rubik[wght].ttf" "$RUBIK_SHA256"
fetch "$rubik_base/Rubik-Italic%5Bwght%5D.ttf" "$WORK/stage-fonts$FONT_DIR/Rubik-Italic[wght].ttf" "$RUBIK_ITALIC_SHA256"
chmod 644 "$WORK/stage-fonts$FONT_DIR"/*.ttf
install_staged fonts "$WORK/stage-fonts"
sudo fc-cache -f "$FONT_DIR"

# ---------------------------------------------------------------- dart-sass (discord theming)
if [[ -x /opt/dart-sass/sass ]] && /opt/dart-sass/sass --version 2>/dev/null | grep -qx "$DART_SASS_VER"; then
    log "dart-sass $DART_SASS_VER already installed, skipping"
else
    log "Installing dart-sass $DART_SASS_VER to /opt/dart-sass (only used for Discord theming)"
    fetch "https://github.com/sass/dart-sass/releases/download/$DART_SASS_VER/dart-sass-$DART_SASS_VER-linux-x64.tar.gz" \
        "$WORK/dart-sass.tar.gz" "$DART_SASS_SHA256"
    mkdir -p "$WORK/stage-sass/opt" "$WORK/stage-sass/usr/local/bin"
    tar -xzf "$WORK/dart-sass.tar.gz" -C "$WORK/stage-sass/opt"
    ln -s /opt/dart-sass/sass "$WORK/stage-sass/usr/local/bin/sass"
    sudo rm -rf /opt/dart-sass
    install_staged dart-sass "$WORK/stage-sass"
fi

# ---------------------------------------------------------------- papirus-folders
if command -v papirus-folders >/dev/null; then
    log "papirus-folders already installed, skipping"
else
    log "Installing papirus-folders $PAPIRUS_FOLDERS_VER to /usr/local"
    fetch "https://github.com/PapirusDevelopmentTeam/papirus-folders/archive/refs/tags/v$PAPIRUS_FOLDERS_VER.tar.gz" \
        "$WORK/papirus-folders.tar.gz" "$PAPIRUS_FOLDERS_SHA256"
    tar -xzf "$WORK/papirus-folders.tar.gz" -C "$WORK"
    make -C "$WORK/papirus-folders-$PAPIRUS_FOLDERS_VER" PREFIX=/usr/local \
        ZSHCOMPDIR=/usr/local/share/zsh/site-functions DESTDIR="$WORK/stage-papirus" install
    install_staged papirus-folders "$WORK/stage-papirus"
fi

# ---------------------------------------------------------------- Arch path compat
# The hypr config starts these via their Arch paths; Gentoo installs them to /usr/libexec.
link_compat() {  # link_compat arch_path gentoo_path
    if [[ -e $1 ]]; then return; fi
    if [[ ! -e $2 ]]; then warn "$2 not found, not linking $1"; return; fi
    log "Linking $1 -> $2"
    sudo mkdir -p "$(dirname "$1")"
    sudo ln -s "$2" "$1"
    echo "$1" | sudo tee -a "$MANIFEST_DIR/compat-links.txt" >/dev/null
}
sudo mkdir -p "$MANIFEST_DIR"
link_compat /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1
geoclue_agent=$(find /usr/libexec /usr/lib64 -path '*geoclue-2.0/demos/agent' -type f 2>/dev/null | head -1 || true)
link_compat /usr/lib/geoclue-2.0/demos/agent "${geoclue_agent:-/usr/libexec/geoclue-2.0/demos/agent}"

# ---------------------------------------------------------------- services / permissions
log "Enabling system services (power-profiles-daemon, bluetooth, NetworkManager)"
sudo systemctl enable --now power-profiles-daemon.service || warn "could not enable power-profiles-daemon"
sudo systemctl enable --now bluetooth.service || warn "could not enable bluetooth"
sudo systemctl enable --now NetworkManager.service || warn "could not enable NetworkManager"

# ddcutil (external monitor brightness) needs i2c-dev loaded and access to /dev/i2c-*
echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf >/dev/null
sudo modprobe i2c-dev || true
if getent group i2c >/dev/null && ! id -nG "$USER" | grep -qw i2c; then
    log "Adding $USER to the i2c group (for ddcutil)"
    sudo usermod -aG i2c "$USER"
fi

# ---------------------------------------------------------------- optional sudoers rules
echo
log "The Caelestia CLI can optionally run two things through passwordless sudo:"
log "  - papirus-folders  (recolour folder icons to match the colour scheme)"
log "  - writing a theme policy for Brave  (live browser theming)"
# Gentoo doesn't always ship /etc/sudoers.d, and /etc/sudoers must include it.
sudo install -d -m 750 /etc/sudoers.d
if ! sudo grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
    warn "/etc/sudoers does not read /etc/sudoers.d, so these rules would have no effect."
    warn "To enable it, run \`sudo visudo\` and add this line at the end:  @includedir /etc/sudoers.d"
fi
if ask "Create /etc/sudoers.d/caelestia-papirus-folders?"; then
    echo "$USER ALL=(ALL) NOPASSWD: $(command -v papirus-folders)" \
        | sudo tee /etc/sudoers.d/caelestia-papirus-folders >/dev/null
    sudo chmod 440 /etc/sudoers.d/caelestia-papirus-folders
    sudo visudo -cf /etc/sudoers.d/caelestia-papirus-folders >/dev/null || { sudo rm -f /etc/sudoers.d/caelestia-papirus-folders; die "invalid sudoers file, removed"; }
fi
if ask "Create /etc/sudoers.d/caelestia-chromium (Brave theming)?"; then
    {
        for dir in /etc/brave/policies/managed; do
            echo "$USER ALL=(ALL) NOPASSWD: $(command -v mkdir) -p $dir"
            echo "$USER ALL=(ALL) NOPASSWD: $(command -v tee) $dir/caelestia.json"
        done
    } | sudo tee /etc/sudoers.d/caelestia-chromium >/dev/null
    sudo chmod 440 /etc/sudoers.d/caelestia-chromium
    sudo visudo -cf /etc/sudoers.d/caelestia-chromium >/dev/null || { sudo rm -f /etc/sudoers.d/caelestia-chromium; die "invalid sudoers file, removed"; }
fi

echo
log "Dependencies installed. Next: ./install-caelestia.sh"
log "Files installed outside portage are listed in $MANIFEST_DIR"
log "Not installed (no Gentoo package, optional): qtengine + darkly (Qt app theming), sweet-cursors (using Bibata instead)."
if ! id -nG "$USER" | grep -qw i2c && getent group i2c >/dev/null; then
    warn "Log out and back in for the i2c group membership to apply."
fi
