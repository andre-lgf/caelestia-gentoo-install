#!/usr/bin/env bash
# System backups for this Gentoo install.
#
#   ./backup-system.sh stage4 <dest> [--no-home] [--credentials FILE]
#       Full-system tarball ("stage4") of / plus the EFI partition, for disaster recovery.
#       <dest> is a folder on another drive (USB/external disk, not on /), an already
#       mounted share (also Thunar/gvfs ones under /run/user/$UID/gvfs), or a Samba URL:
#         smb://[user@]server/share[/folder]   (mounted for the run, password prompted;
#         --credentials FILE uses a mount.cifs credentials file instead)
#
#   ./backup-system.sh config [repo-dir]          (default: ~/gentoo-config)
#       Copies the files that define the system (portage config, world file, kernel
#       config, fstab, enabled services, Caelestia user config...) into a git repo
#       and commits. Small; run it after changes.
#
#   ./backup-system.sh binpkgs
#       Enables FEATURES=buildpkg (every emerge also keeps a binary package) and
#       packages everything already installed with quickpkg, so a reinstall can use
#       `emerge --usepkg` instead of compiling.
#
# Run as your normal user; it uses sudo where needed.

set -euo pipefail

c_info=$'\e[1;36m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
log()  { printf '%s::%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
ask()  { local r; read -r -p "$1 [y/N] " r; [[ $r == [yY]* ]]; }
usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit "${1:-0}"; }

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it uses sudo)."

# ================================================================ stage4
SMB_MNT=""
KEEPALIVE=""
cleanup() {
    [[ -n $KEEPALIVE ]] && kill "$KEEPALIVE" 2>/dev/null
    if [[ -n $SMB_MNT ]]; then
        sudo umount "$SMB_MNT" 2>/dev/null || sudo umount -l "$SMB_MNT" 2>/dev/null || true
        rmdir "$SMB_MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Mount smb://[user@]host/share[/sub/dir] (or //host/share/...) and print the local dir
mount_smb() {  # mount_smb url credentials-file
    local url=$1 creds=$2 user host share sub
    url=${url#smb:}; url=${url#//}
    if [[ $url == *@* ]]; then user=${url%%@*}; url=${url#*@}; fi
    host=${url%%/*}; url=${url#"$host"}; url=${url#/}
    share=${url%%/*}; sub=${url#"$share"}; sub=${sub#/}
    [[ -n $host && -n $share ]] || die "can't parse SMB location; use smb://[user@]server/share[/folder]"

    local opts="uid=$(id -u),gid=$(id -g),file_mode=0600,dir_mode=0700"
    if [[ -n $creds ]]; then
        [[ -r $creds ]] || die "can't read credentials file $creds"
        opts+=",credentials=$(realpath "$creds")"
    else
        [[ -n ${user:-} ]] || read -r -p "SMB user for //$host/$share [$USER]: " user
        opts+=",username=${user:-$USER}"
    fi

    SMB_MNT=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/backup-smb.XXXXXX")
    log "Mounting //$host/$share (you'll be asked for the SMB password unless a credentials file is used)" >&2
    sudo mount -t cifs "//$host/$share" "$SMB_MNT" -o "$opts" >&2 \
        || { rmdir "$SMB_MNT"; SMB_MNT=""; die "mount of //$host/$share failed"; }
    mkdir -p "$SMB_MNT/$sub" || die "can't create $sub on the share"
    printf '%s\n' "$SMB_MNT${sub:+/$sub}"
}

# Run a command producing an uncompressed tar on stdout; compress and write it as *you*
# (works on SMB/gvfs mounts root can't write to) and checksum it on the fly.
STREAM_RC=0
write_stream() {  # write_stream out sumfile cmd...
    local out=$1 sumfile=$2 sumtmp; shift 2
    sumtmp=$(mktemp)
    set +e
    "$@" | zstd -T0 -6 -q -c | tee "$out" | sha256sum >"$sumtmp"
    local st=("${PIPESTATUS[@]}")
    set -e
    STREAM_RC=${st[0]}
    if ((st[1] || st[2] || st[3])); then
        rm -f "$sumtmp"; die "writing $out failed (zstd/tee/sha256sum: ${st[1]}/${st[2]}/${st[3]})"
    fi
    echo "$(cut -d' ' -f1 "$sumtmp")  ${out##*/}" >>"$sumfile"
    rm -f "$sumtmp"
}

cmd_stage4() {
    local dest="" home=true creds=""
    while (($#)); do
        case $1 in
            --no-home) home=false ;;
            --credentials) shift; creds=${1:-} ;;
            --credentials=*) creds=${1#*=} ;;
            -*) die "unknown option $1" ;;
            *) [[ -z $dest ]] && dest=$1 || die "only one destination allowed" ;;
        esac
        shift
    done
    [[ -n $dest ]] || usage 1

    sudo -v
    # Keep sudo alive during the long tar run
    while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    KEEPALIVE=$!

    if [[ $dest == smb://* || $dest == //* ]]; then
        command -v mount.cifs >/dev/null || die "mount.cifs not found (emerge net-fs/cifs-utils)."
        dest=$(mount_smb "$dest" "$creds")
    fi
    [[ -d $dest ]] || die "$dest does not exist (mount your backup drive first)."
    [[ -w $dest ]] || die "you can't write to $dest."
    dest=$(realpath "$dest")

    # Refuse to back up onto the disk being backed up
    local root_src dest_src dest_fs root_disk dest_disk
    root_src=$(findmnt -no SOURCE /)
    dest_src=$(findmnt -no SOURCE -T "$dest")
    dest_fs=$(findmnt -no FSTYPE -T "$dest")
    [[ $dest_src != "$root_src" ]] || die "$dest is on the root filesystem ($root_src); use another drive or a network share."
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)
    dest_disk=$(lsblk -no PKNAME "$dest_src" 2>/dev/null || true)
    if [[ -n $root_disk && $root_disk == "$dest_disk" ]]; then
        warn "$dest is on the same physical disk ($root_disk) as /; it won't survive a disk failure."
        ask "Continue anyway?" || exit 1
    fi
    log "Destination: $dest ($dest_fs on $dest_src)"

    local stamp host base out efi_out notes sums
    stamp=$(date +%Y%m%d-%H%M)
    host=$(hostname)
    base="$dest/stage4-$host-$stamp"
    out="$base.tar.zst"
    efi_out="$dest/efi-$host-$stamp.tar.zst"
    notes="$base.RESTORE.txt"
    sums="$base.sha256"

    local used
    used=$(df -BG --output=used / | tail -1 | tr -dc 0-9)
    log "Root uses ${used}G; the compressed archive is usually 40-60% of that. Free on destination:"
    df -h --output=avail "$dest" 2>/dev/null | tail -1 || echo "  (unknown)"

    local excludes=(
        ./proc ./sys ./dev ./run ./tmp ./mnt ./media ./lost+found
        ./var/tmp ./var/cache/distfiles ./var/cache/binpkgs ./var/db/repos
        ./var/cache/edb/dep ./var/log/journal
        './home/*/.cache' './home/*/.local/share/Trash'
        './root/.cache'
    )
    $home || excludes+=('./home/*')
    # If the destination is a local path under /, don't archive the archive
    [[ $dest == /* ]] && excludes+=(".$dest")
    local tar_excl=()
    for e in "${excludes[@]}"; do tar_excl+=(--exclude="$e"); done

    : >"$sums"
    log "Writing $out (this takes a while; over the network, a lot longer)..."
    write_stream "$out" "$sums" sudo tar -cp -f - -C / \
        --xattrs --xattrs-include='*.*' --acls --numeric-owner --one-file-system \
        --warning=no-file-ignored --warning=no-file-changed --warning=no-file-removed \
        "${tar_excl[@]}" .
    # tar exits 1 when files changed while reading (normal on a running system)
    ((STREAM_RC <= 1)) || die "tar failed (exit $STREAM_RC); the archive is incomplete."
    ((STREAM_RC == 0)) || warn "some files changed while archiving (normal on a running system)."

    # EFI partition (separate vfat, noauto in fstab)
    local mounted_efi=false
    if ! mountpoint -q /boot/efi; then
        sudo mount -o ro /boot/efi && mounted_efi=true
    fi
    if mountpoint -q /boot/efi; then
        log "Writing $efi_out"
        write_stream "$efi_out" "$sums" sudo tar -cp -f - -C /boot/efi .
        ((STREAM_RC == 0)) || warn "tar of the EFI partition exited $STREAM_RC"
    else
        warn "couldn't mount /boot/efi; EFI partition not backed up."
    fi
    $mounted_efi && sudo umount /boot/efi

    # Restore notes + partition layout
    {
        echo "Stage4 of $host taken $(date -R)"
        echo "Kernel: $(uname -r)   Home included: $home"
        echo
        echo "== Partition layout =="; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS
        echo; echo "== /etc/fstab =="; cat /etc/fstab
        cat <<'EOF'

== Restore (from a live USB) ==
 0. If the backup is on an SMB share: mount -t cifs //server/share /mnt/backup -o username=USER
 1. Partition/format as above (ext4 root, vfat EFI, swap), e.g. mkfs.ext4 /dev/XXX
 2. mount /dev/<root> /mnt/gentoo
 3. sha256sum -c stage4-*.sha256      (in the backup folder)
 4. tar -xp -f stage4-*.tar.zst -C /mnt/gentoo --use-compress-program=zstd \
        --xattrs --xattrs-include='*.*' --acls --numeric-owner
 5. mkdir -p /mnt/gentoo/{proc,sys,dev,run,tmp,var/tmp,mnt,media} && chmod 1777 /mnt/gentoo/{tmp,var/tmp}
 6. Fix /mnt/gentoo/etc/fstab if the partition names changed (it uses /dev/nvme0n1pX)
 7. EFI: mount /dev/<efi> /mnt/gentoo/boot/efi; either restore efi-*.tar.zst into it, or
    reinstall the bootloader in step 9 (keeps the Windows boot entry if you only reinstall grub)
 8. arch-chroot /mnt/gentoo   (or mount --rbind /proc /sys /dev /run and chroot)
 9. grub-install --efi-directory=/boot/efi && grub-mkconfig -o /boot/grub/grub.cfg
10. emerge-webrsync (or emerge --sync) since /var/db/repos was not included
EOF
    } >"$notes"

    chmod 600 "$out" "$notes" "$sums" 2>/dev/null || true
    [[ -f $efi_out ]] && { chmod 600 "$efi_out" 2>/dev/null || true; }
    log "Checksums ($sums):"
    cat "$sums"

    log "Done: $(du -h "$out" | cut -f1) $out"
    [[ -n $SMB_MNT ]] && log "(on the share; it will be unmounted now)"
    warn "It contains password hashes, SSH host keys, Wi-Fi passwords etc. Keep it private"
    [[ $dest_fs == cifs || $dest_fs == smb3 || $dest_fs == fuse* ]] \
        && warn "and check who can read that folder on the server: file permissions on a share are up to the server."
}

# ================================================================ config
cmd_config() {
    local repo=${1:-$HOME/gentoo-config}
    mkdir -p "$repo"
    [[ -d $repo/.git ]] || git -C "$repo" init -q
    sudo -v

    log "Collecting system config into $repo"
    local sys=$repo/system
    rm -rf "$sys"; mkdir -p "$sys/etc" "$sys/kernel"

    # Root-readable trees, copied as you
    sudo tar -C / -cf - etc/portage etc/fstab etc/default/grub etc/sddm.conf.d \
            etc/modules-load.d etc/locale.gen etc/vconsole.conf etc/hostname 2>/dev/null \
        | tar -C "$sys" -xf - --no-same-owner --no-same-permissions || true
    # make.profile is a symlink into the repo; record where it points instead
    readlink /etc/portage/make.profile >"$sys/make.profile.txt"
    rm -f "$sys/etc/portage/make.profile"

    cp /var/lib/portage/world "$sys/world"
    [[ -f /var/lib/portage/world_sets ]] && cp /var/lib/portage/world_sets "$sys/world_sets"
    [[ -f /usr/src/linux/.config ]] && cp /usr/src/linux/.config "$sys/kernel/config-$(uname -r)"

    qlist -IRv | sort >"$sys/installed-packages.txt"
    eselect repository list -i 2>/dev/null >"$sys/repositories.txt" || true
    systemctl list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' >"$sys/enabled-units.txt"
    systemctl --user list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' >"$sys/enabled-user-units.txt"

    # User config (Caelestia personal files; the dots themselves are managed by the CLI)
    local usr=$repo/user
    rm -rf "$usr"; mkdir -p "$usr/.config"
    [[ -d $HOME/.config/caelestia ]] && cp -a "$HOME/.config/caelestia" "$usr/.config/"
    for f in kitty fish/config.fish; do
        [[ -e $HOME/.config/$f ]] && { mkdir -p "$usr/.config/$(dirname "$f")"; cp -a "$HOME/.config/$f" "$usr/.config/$f"; }
    done
    [[ -d ${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-gentoo/gifs ]] \
        && rsync -a --exclude dl "${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-gentoo/gifs/" "$usr/caelestia-gifs/"

    [[ -f $repo/README.md ]] || cat >"$repo/README.md" <<'EOF'
# gentoo-config

Snapshot of what defines this Gentoo system, made by `caelestia-gentoo/backup-system.sh config`.

- `system/etc/portage`, `system/world`: reinstall with `emerge --ask --noreplace @world`
  after copying `etc/portage` into place and setting the profile from `make.profile.txt`.
- `system/kernel/`: kernel .config.
- `system/enabled-units.txt`: `systemctl enable` these.
- `user/`: personal config (Caelestia overrides, kitty, fish).
EOF

    git -C "$repo" add -A
    if git -C "$repo" diff --cached --quiet; then
        log "No changes since the last snapshot."
    else
        git -C "$repo" commit -q -m "Snapshot $(date '+%Y-%m-%d %H:%M')"
        log "Committed: $(git -C "$repo" log -1 --format='%h %s')"
        git -C "$repo" diff --stat HEAD~1 2>/dev/null | tail -1 || true
    fi
    log "Push it somewhere private if you want an off-machine copy (it has no secrets, but it's personal)."
}

# ================================================================ binpkgs
cmd_binpkgs() {
    local pkgdir
    pkgdir=$(portageq pkgdir)
    sudo -v

    if portageq envvar FEATURES | tr ' ' '\n' | grep -qx buildpkg; then
        log "FEATURES=buildpkg is already enabled."
    elif ask "Add FEATURES=\"buildpkg\" to /etc/portage/make.conf (keep a binary package of every emerge)?"; then
        sudo cp -a /etc/portage/make.conf "/etc/portage/make.conf.bak-$(date +%Y%m%d)"
        printf '\n# Keep binary packages of everything emerged (caelestia-gentoo/backup-system.sh)\nFEATURES="${FEATURES} buildpkg"\n' \
            | sudo tee -a /etc/portage/make.conf >/dev/null
        log "Added. Backup of the old file: /etc/portage/make.conf.bak-$(date +%Y%m%d)"
    fi

    local n
    n=$(qlist -I | wc -l)
    echo
    log "quickpkg packages the $n already-installed packages into $pkgdir."
    log "It needs roughly the size of /usr compressed (several GB) and ~10-30 minutes."
    df -h --output=avail "$pkgdir" 2>/dev/null | tail -1 || df -h --output=avail /var | tail -1
    if ask "Run quickpkg for everything now?"; then
        # --include-config=n (default): protected config files stay out of the packages,
        # so they hold no local secrets; your configs live in the stage4 / config repo.
        sudo quickpkg --include-config=n "*/*"
        log "Done: $(sudo du -sh "$pkgdir" | cut -f1) in $pkgdir"
    fi
    echo
    log "To reinstall from them later: emerge --ask --usepkg --with-bdeps=y @world"
    log "Copy $pkgdir with your stage4 (it's excluded from the stage4 tarball to keep it small)."
}

# ================================================================ main
case ${1:-} in
    stage4)  shift; cmd_stage4 "$@" ;;
    config)  shift; cmd_config "$@" ;;
    binpkgs) shift; cmd_binpkgs "$@" ;;
    -h|--help|"") usage 0 ;;
    *) usage 1 ;;
esac
