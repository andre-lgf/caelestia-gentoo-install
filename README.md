# caelestia-gentoo-install

Scripts to install [Caelestia](https://github.com/caelestia-dots/caelestia) (the
[shell](https://github.com/caelestia-dots/shell), [CLI](https://github.com/caelestia-dots/cli)
and dotfiles) on **Gentoo**, plus the [Caelestia SDDM theme](https://github.com/ItsABigIgloo/caelestia-sddm)
and a system backup helper.

Caelestia targets Arch Linux. These scripts map its Arch packages to Gentoo ones,
build what Gentoo doesn't package from pinned and checksummed sources, and work
around the places where the upstream tooling assumes `pacman`.

| Script | What it does |
|---|---|
| [`install-deps.sh`](#1-install-depssh) | Installs every dependency (emerge + a few source builds) |
| [`install-caelestia.sh`](#2-install-caelestiash) | Builds/installs the shell and the CLI, then deploys the dotfiles |
| [`install-sddm-theme.sh`](#3-install-sddm-themesh-optional) | Optional: Caelestia login screen for SDDM |
| [`backup-system.sh`](#4-backup-systemsh-optional) | Optional: stage4 image, config snapshot, binary packages |

All scripts are meant to be run **as your normal user** (they call `sudo` themselves)
and are safe to re-run.

---

## Requirements

- Gentoo, amd64, **systemd** profile (tested on `default/linux/amd64/23.0/desktop/systemd`).
- **Hyprland** (Lua config, 0.56+) and **Quickshell** already installed.
- The `::guru` and `::hyproverlay` overlays:
  ```sh
  sudo eselect repository enable guru hyproverlay
  sudo emaint sync -r guru -r hyproverlay
  ```
- `git`, `curl` and `sudo`.

## Quick start

```sh
git clone https://github.com/andre-lgf/caelestia-gentoo-install.git
cd caelestia-gentoo-install
./install-deps.sh
./install-caelestia.sh        # best run from a terminal inside Hyprland
./install-sddm-theme.sh       # optional
```

Then log out and back in (or reboot). The shell starts with Hyprland.

---

## 1. `install-deps.sh`

```sh
./install-deps.sh
```

What it does:

1. Checks that `::guru` and `::hyproverlay` are enabled.
2. Writes the keywords/USE flags Caelestia needs to
   `/etc/portage/package.accept_keywords/caelestia-gentoo` and
   `/etc/portage/package.use/caelestia-gentoo` (your own files are not touched).
3. Asks whether to switch Quickshell to the live `9999` ebuild (default **no**: your
   installed version is kept).
4. Emerges the packages (`emerge --ask`, so you confirm the list). Any extra
   keyword/USE change portage needs is applied with `--autounmask-continue`.
5. Builds/installs what has no Gentoo package, from pinned commits with SHA-256 checks:
   - **m3shapes** (QML module) → `/usr/lib64/qt6/qml`
   - **Material Symbols** and **Rubik** fonts → `/usr/local/share/fonts/caelestia`
   - **dart-sass** → `/opt/dart-sass` (`/usr/local/bin/sass`)
   - **papirus-folders** → `/usr/local`
6. Adds compatibility symlinks for paths the dotfiles expect from Arch (polkit agent,
   geoclue agent).
7. Enables `power-profiles-daemon`, `bluetooth` and `NetworkManager`; loads `i2c-dev`
   and adds you to the `i2c` group (external monitor brightness via ddcutil).
8. Optionally creates two narrow passwordless-sudo rules, each asked separately:
   - `papirus-folders` (recolour folder icons with the colour scheme)
   - Brave theme policy (live browser theming)

Notes:

- Arch → Gentoo substitutions: **pavucontrol** instead of pwvucontrol, **Bibata**
  cursors instead of sweet-cursors. Not installed (no Gentoo package, optional):
  qtengine + darkly (Qt app theming).
- Expect ~100 new packages and a few GB (most of it is Noto fonts).
- Every file installed outside portage is listed in
  `/usr/local/share/caelestia-gentoo/manifests/`.

## 2. `install-caelestia.sh`

```sh
./install-caelestia.sh [extra args for `caelestia install`]
# e.g.
./install-caelestia.sh --enable-components nvim,uwsm
```

Run it from a terminal **inside Hyprland** so the post-install hooks (reloading
Hyprland, starting the shell) can run.

What it does:

1. Backs up the configs the dotfiles will replace (`hypr`, `fish`, `foot`, `fastfetch`,
   `btop`, `Thunar`, …) to `~/caelestia-config-backup-<date>/`.
2. Builds **caelestia-shell** (pinned tag) and installs it to
   `/etc/xdg/quickshell/caelestia` + its QML plugin in `/usr/lib64/qt6/qml/Caelestia`.
3. Builds **caelestia-cli** (pinned tag) into a venv at `/opt/caelestia-cli` (using the
   system's Pillow/materialyoucolor) and links `/usr/local/bin/caelestia`.
   A local fix is applied so screen recordings started from the shell panel don't die
   after a second (the recorder inherited a pipe the shell closes → SIGPIPE).
4. Creates starter user overrides if you don't have them (see below).
5. Runs `caelestia install --disable-components firefox` to deploy the dotfiles
   (Firefox is skipped; set `DISABLE_COMPONENTS` in the script to change that).
   Off Arch, the CLI skips package installation and only deploys files.

### Updating

- **Dotfiles:** `caelestia update`.
- **Shell / CLI:** bump `SHELL_TAG` / `CLI_TAG` at the top of the script and re-run it.
  Files from the previous version are removed using the install manifest.

### Customising without losing changes

The dotfiles are managed by the CLI and get overwritten on update. Put your changes in
these files instead; they are never overwritten:

| File | Use it for |
|---|---|
| `~/.config/caelestia/hypr-vars.lua` | Override variables from `~/.config/hypr/variables.lua`: apps (`terminal`, `browser`, `editor`…), keybinds (`kbLock`, `kbClipboard`…; a list gives several keys), cursor theme |
| `~/.config/caelestia/hypr-user.lua` | Anything else for Hyprland, loaded last: extra binds (`hl.bind`), input settings (`hl.config`), workspace/window rules, autostart (`hl.on("hyprland.start", …)`) |
| `~/.config/caelestia/shell.json` | Shell settings: apps (`general.apps.terminal`, `audio`…), idle/lock timeouts (`general.idle`), images (`paths.mediaGif`, `paths.sessionGif`)… Reloaded live |
| `~/.config/caelestia/cli.json` | CLI settings: recording args (`record.extraArgs`), wallpaper/theme post-hooks, special-workspace app toggles |

Apply Hyprland changes with `hyprctl reload`; the shell picks up `shell.json` live.
Restart the shell with **Ctrl+Super+Alt+R** (Ctrl+Super+**Shift**+R *kills* it).

### Uninstalling

```sh
# shell and CLI files (and the source-built deps from install-deps.sh)
cat /usr/local/share/caelestia-gentoo/manifests/*.txt   # review first
cat /usr/local/share/caelestia-gentoo/manifests/*.txt | grep "^/" | sudo xargs -d "\n" rm -f
sudo rm -rf /opt/caelestia-cli /opt/dart-sass
```

Your previous configs are in `~/caelestia-config-backup-<date>/` (and the CLI keeps its
own copy in `~/.config.bak`).

## 3. `install-sddm-theme.sh` (optional)

```sh
./install-sddm-theme.sh [locklike|minimalist|minimalistV2]
```

Installs the [Caelestia SDDM theme](https://github.com/ItsABigIgloo/caelestia-sddm)
(pinned commit) as the login screen; its upstream installer only works with `pacman`.
Run from inside Hyprland.

- Without an argument it asks which theme to use (default **locklike**, which looks like
  the Caelestia lock screen).
- Installs the extra dependencies (`qt5compat`, `qtmultimedia`, `qtimageformats`, Roboto)
  and the `sys-libs/zlib minizip` USE flag they need.
- Installs the theme to `/usr/share/sddm/themes/caelestia` and selects it in
  `/etc/sddm.conf.d/caelestia.conf` (keeps Gentoo's X11 greeter, which the theme needs).
- Syncs your current colour scheme and wallpaper to the login screen.
- Asks whether to **keep it in sync automatically**: adds a passwordless-sudo rule for
  the theme's `sync.sh` only, and wallpaper/theme post-hooks to `~/.config/caelestia/cli.json`.
- Asks whether to enable SDDM (if it isn't already).

Afterwards:

```sh
# preview without logging out
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=xcb sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/caelestia
# manual sync (after changing ~/.face, the template, …)
sudo /usr/share/sddm/themes/caelestia/scripts/sync.sh
```

- Avatar: put an image at `~/.face`, then sync.
- Theme options (clock format, blur…): edit `~/.config/caelestia/templates/sddm-theme.conf`.
- If SDDM fails to start: **Ctrl+Alt+F2**, log in, `sudo systemctl disable sddm`, reboot.

The lock screen itself is Caelestia's (Super+L, on idle, and before suspend); SDDM is
only the login screen.

## 4. `backup-system.sh` (optional)

General Gentoo backup helper with three commands.

### `stage4`: full system image

```sh
./backup-system.sh stage4 <dest> [--no-home] [--credentials FILE]

./backup-system.sh stage4 /run/media/$USER/MyUSB/backups
./backup-system.sh stage4 smb://user@nas/backups/gentoo          # Samba share, password prompted
./backup-system.sh stage4 //nas/backups --credentials ~/.config/smb-backup.cred
```

- Archives `/` (including `/boot` and `/home`; `--no-home` skips it) into
  `stage4-<host>-<date>.tar.zst`, keeping permissions, ACLs and file capabilities.
- Also archives the EFI partition (mounted read-only if needed) to `efi-<host>-<date>.tar.zst`.
- Skips caches, trash, `/var/db/repos` (re-sync it), distfiles and binpkgs.
- Writes a `.sha256` (computed while writing) and a `.RESTORE.txt` with your partition
  layout, fstab and step-by-step restore instructions.
- Destination can be a local folder on **another drive** (writing to the root filesystem
  is refused; the same physical disk asks first), an already mounted share (including
  Thunar/gvfs mounts), or an `smb://` / `//server/share` address, which is mounted for
  the run and unmounted afterwards (needs `net-fs/cifs-utils`).
- A credentials file for `--credentials` (keep it `chmod 600`, outside any repo):
  ```
  username=USER
  password=PASSWORD
  domain=WORKGROUP
  ```

> **The archive contains password hashes, SSH host keys and Wi-Fi passwords.**
> Keep it private and check who can read the folder on the server. It is meant for
> restoring *this* machine (CPU-specific `-march` builds, fstab, kernel), not as a base
> for other systems.

Close browsers/editors first for the cleanest image; ideally run it from a live USB.

### `config`: snapshot what defines the system

```sh
./backup-system.sh config [repo-dir]     # default: ~/gentoo-config
```

Copies `/etc/portage`, the world file, the kernel `.config`, fstab, GRUB/SDDM settings,
installed-package and enabled-service lists, and your Caelestia/kitty/fish config into a
git repo and commits what changed. No secrets are copied, but it's a detailed map of your
machine: if you push it, use a **private** repo.

### `binpkgs`: never compile the same thing twice

```sh
./backup-system.sh binpkgs
```

- Asks to add `FEATURES="${FEATURES} buildpkg"` to `/etc/portage/make.conf` (backs up the
  old file first), so every emerge keeps a binary package.
- Offers to package everything already installed with `quickpkg` (several GB, 10-30 min).
- Reinstall later with `emerge --ask --usepkg --with-bdeps=y @world`. Copy
  `/var/cache/binpkgs` along with your stage4.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Shell not running after login | `caelestia shell -d`; logs in `/run/user/$UID/quickshell/by-id/*/log.log` |
| Shell disappeared ("Exiting due to IPC request" in the log) | It was killed (Ctrl+Super+Shift+R / `caelestia shell -k`); start it again |
| `git`/`curl` fail with odd DNS or TLS errors (e.g. certificate for a different host) | Some routers break EDNS DNS replies, which affects curl/libcurl but not browsers; use a public resolver (e.g. 1.1.1.1) in NetworkManager |
| Recording with sound has missing/short audio | Use AAC: `"record": {"extraArgs": ["-ac", "aac"]}` in `~/.config/caelestia/cli.json` |
| Clock off by a few hours with Windows dual boot | `sudo timedatectl set-ntp true` and make Windows use a UTC hardware clock (`RealTimeIsUniversal`) |

## Credits

[caelestia-dots](https://github.com/caelestia-dots) for Caelestia,
[ItsABigIgloo/caelestia-sddm](https://github.com/ItsABigIgloo/caelestia-sddm) for the SDDM
theme. This repo only contains install glue for Gentoo.
