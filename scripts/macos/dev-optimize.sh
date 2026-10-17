#!/usr/bin/env bash
set -u -o pipefail

# ==============================================================================
# macOS dev-workstation optimisation for this Mac (MacBookPro15,2, 8 GB RAM,
# macOS 15.8.1, single 500 GB APFS container).
#
# Design notes (each verified against the live machine before this was written):
#
#  * DRY-RUN BY DEFAULT. Every mutating step prints the exact command it would
#    run. Nothing changes until you pass --apply. Deletions also go through
#    safe_rm(), which refuses "", "/", "$HOME", "$DEV_DIR" and any non-absolute
#    path, so a bad variable expansion cannot wipe a home directory.
#
#  * This script is meant to be run BY THE HUMAN, not by an automated agent.
#    It needs sudo for the volume/daemon/pmset steps, and the agent sandbox on
#    this machine denies sudo entirely ("/usr/bin/sudo: Operation not
#    permitted"), so nothing privileged can be scripted from the assistant.
#
#  * The Dev volume move is NOT automated here. Unmounting the volume that your
#    own shell/IDE/agent is currently living in is a one-way operation with a
#    real failure mode (half-copied tree), so it stays a hand-run runbook with
#    an explicit verify gate. See docs/macos-dev-workstation.md section 5.
#
#  * Why a volume at all: ~/Dev is 3.9 GB but 206,882 files, of which 196,387
#    (95%) are node_modules. The point is not space (116 GiB is free) -- it is
#    excluding that file count from Spotlight and the fsevents journal. APFS
#    volumes in one container share the free-space pool, so there is no space
#    or I/O-isolation gain; the gain is a durable daemon-policy boundary.
#
#  * Why bun's cache must live on the SAME volume as the repos: Bun uses
#    clonefile() on macOS (copy-on-write), not hardlinks. clonefile only works
#    within a volume; across volumes Bun silently falls back to copyfile, which
#    is slower AND materialises a full second copy. Cache and projects are
#    therefore co-located on the Dev volume (see post-volume).
#
#  * Ordering matters. Toolchain cleanup runs before the volume move so the
#    tree to copy is small; the node_modules purge happens after a successful
#    frozen-lockfile install proves the tree is reproducible.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || pwd)"

DEV_DIR="${DEV_DIR:-$HOME/Dev}"
REPOS_DIR="$DEV_DIR/Repos"
PROD_HOST="${PROD_HOST:-root@dejis-cloud}"
PROD_BACKUP_ROOT="${PROD_BACKUP_ROOT:-/root/dev-backup}"
BUN_CACHE_DIR="$DEV_DIR/.cache/bun/install/cache"
DATE_TAG="$(date +%F)"
BACKUP_MODE="${BACKUP_MODE:-rsync}"

APPLY=0
REMOVE_APPS=0
REMOVE_COLIMA=0
REMOVE_TOOLCHAINS=0
DELETE_CREDS=0

# ---------------------------------------------------------------- output utils

if [ -t 1 ]; then
    C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLD=; C_OFF=
fi

say()  { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
ok()   { printf '%s ok %s %s\n' "$C_GRN" "$C_OFF" "$*"; }
bad()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }

run() {
    if (( APPLY )); then
        dim "  \$ $*"
        "$@"
    else
        dim "  [dry-run] $*"
    fi
}

run_in() {
    local dir="$1"; shift
    if (( APPLY )); then
        dim "  \$ (cd $dir && $*)"
        ( cd "$dir" && "$@" )
    else
        dim "  [dry-run] (cd $dir && $*)"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

du_h() {
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then
            printf '  %8s  %s\n' "$(du -sh "$p" 2>/dev/null | cut -f1)" "$p"
        fi
    done
}

# Deletion guard: absolute paths only, and never the home/dev roots themselves.
safe_rm() {
    local p
    for p in "$@"; do
        case "$p" in
            ""|"/"|"$HOME"|"$HOME/"|"$DEV_DIR"|"$DEV_DIR/"|"/Users"|"/Applications"|"/System"|"/Library")
                die "refusing to delete dangerous path: '${p}'" ;;
        esac
        [ "${p#/}" != "$p" ] || die "refusing to delete non-absolute path: '$p'"
    done
    run rm -rf -- "$@"
}

# ------------------------------------------------------------------ subcommands

cmd_backup() {
    require_dev_dir
    section "Backup ~/Dev to $PROD_HOST"

    local dest_dir="$PROD_BACKUP_ROOT-$DATE_TAG"
    say "  source : $DEV_DIR/ (node_modules and .DS_Store excluded)"
    say "  target : $PROD_HOST:$dest_dir/"
    say "  mode   : $BACKUP_MODE"

    if [ "$BACKUP_MODE" = "tar" ]; then
        # One stream instead of ~10k per-file round trips. Measured on this
        # link: rsync averaged ~74 kB/s over many small files while a single
        # large file reached 23.8 MB/s, so the bottleneck was rsync protocol
        # overhead, not bandwidth. gzip also shrinks text-heavy source.
        run bash -c "tar -czf - -C '$DEV_DIR' --exclude 'node_modules' --exclude '.DS_Store' . \
            | ssh -o BatchMode=yes '$PROD_HOST' 'mkdir -p $dest_dir && cat > $dest_dir/dev.tar.gz'"
    else
        local rsync_bin
        rsync_bin="$(command -v /usr/local/bin/rsync 2>/dev/null || command -v rsync || true)"
        [ -n "$rsync_bin" ] || die "rsync not found"
        dim "  using $rsync_bin ($("$rsync_bin" --version | head -1))"
        run "$rsync_bin" -aHAX --info=progress2 --stats \
            --exclude 'node_modules/' --exclude '.DS_Store' \
            "$DEV_DIR/" "$PROD_HOST:$dest_dir/"
    fi

    # Dotfiles: the machine is not rebuildable without these. ~/.git-credentials
    # is deliberately excluded -- it holds a plaintext token and is deleted later.
    local -a dotfiles=()
    local f
    for f in .zshrc .zprofile .zshenv .gitconfig .npmrc .bunfig.toml .config/git/config; do
        [ -f "$HOME/$f" ] && dotfiles+=("$f")
    done
    if (( ${#dotfiles[@]} )); then
        say "  dotfiles: ${dotfiles[*]}"
        if (( APPLY )); then
            ( cd "$HOME" && tar -czf - "${dotfiles[@]}" ) \
                | ssh -o BatchMode=yes "$PROD_HOST" "mkdir -p '$dest_dir' && cat > '$dest_dir/dotfiles.tar.gz'"
            dim "  \$ tar -czf - ${dotfiles[*]} | ssh $PROD_HOST 'cat > .../dotfiles.tar.gz'"
        else
            dim "  [dry-run] tar -czf - ${dotfiles[*]} | ssh $PROD_HOST 'cat > .../dotfiles.tar.gz'"
        fi
    fi

    section "Verify backup on $PROD_HOST"
    local local_env
    local_env=$(find "$DEV_DIR" -name '.env*' -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')
    say "  local .env* files: $local_env"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$PROD_HOST" \
        "test -d '$dest_dir'" 2>/dev/null; then
        warn "no backup directory on $PROD_HOST yet (dry-run, or the transfer failed)"
        return 0
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$PROD_HOST" "
        chmod 700 '$dest_dir'
        echo \"remote size   : \$(du -sh '$dest_dir' | cut -f1)\"
        if [ -f '$dest_dir/dev.tar.gz' ]; then
            echo \"archive       : \$(du -h '$dest_dir/dev.tar.gz' | cut -f1)\"
            echo \"archive files : \$(tar -tzf '$dest_dir/dev.tar.gz' 2>/dev/null | grep -v '/\$' | wc -l)\"
            echo \"archive .env  : \$(tar -tzf '$dest_dir/dev.tar.gz' 2>/dev/null | grep -c '/\.env')\"
        else
            echo \"remote .env   : \$(find '$dest_dir' -name '.env*' | wc -l)\"
        fi
        echo \"dotfiles      : \$(ls -1 '$dest_dir'/dotfiles.tar.gz 2>/dev/null | wc -l)\"
        df -h / | tail -1
    " || warn "remote verification failed -- check ssh access before trusting this backup"
}

cmd_cleanup_toolchain() {
    section "Retire pnpm / npm / yarn caches (keep npm+npx binaries)"
    say "  Reclaiming (approx):"
    du_h "$HOME/Library/pnpm" "$HOME/Library/Caches/pnpm" "$HOME/.npm" \
         "$HOME/Library/Caches/Yarn" "$HOME/.cache/node"

    say ""
    say "  pnpm globals that disappear (use bunx instead):"
    have pnpm && pnpm ls -g --depth=0 2>/dev/null | sed 's/^/    /' || dim "    (pnpm not on PATH)"

    # npm cache + the pnpm global install. npm/npx stay: npx is only a few MB and
    # glorious-eagles' preinstall hook calls it (until bun-align fixes that).
    run npm uninstall -g pnpm
    run npm cache clean --force
    safe_rm "$HOME/.npm"
    safe_rm "$HOME/Library/pnpm" "$HOME/Library/Caches/pnpm"

    if have brew && brew list --formula 2>/dev/null | grep -qx yarn; then
        run brew uninstall yarn
    fi
    safe_rm "$HOME/Library/Caches/Yarn" "$HOME/.yarnrc"

    if have corepack; then
        run corepack disable
    fi
    safe_rm "$HOME/.cache/node/corepack"

    section "Prune nvm (keep v22 LTS + current default)"
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.nvm/nvm.sh"
        local current; current="$(nvm current 2>/dev/null || echo none)"
        say "  current: $current"
        local v
        for v in v18.12.0 v18.12.1 v18.17.1 v18.18.0 v18.18.2 v20.11.1; do
            if [ -d "$HOME/.nvm/versions/node/$v" ] && [ "$current" != "$v" ]; then
                run nvm uninstall "$v"
            fi
        done
    else
        warn "nvm.sh not found; prune node versions manually"
    fi

    say ""
    say "  Manual follow-up: remove the '# pnpm' ... '# pnpm end' block from ~/.zshrc"
    say "  (run: $0 zshrc --apply)"
}

cmd_bun_align() {
    require_dev_dir
    have bun || die "bun not found on PATH"
    local bunver; bunver="$(bun -v)"
    section "Align every repo to bun@$bunver and dedupe lockfiles"

    local d
    for d in "$REPOS_DIR"/*/; do
        [ -f "${d}bun.lock" ] || [ -f "${d}bun.lockb" ] || continue
        local name; name="$(basename "$d")"
        say ""
        say "  -- $name"

        # bun never rewrites packageManager on install; set it explicitly.
        run_in "$d" bun pm pkg set "packageManager=bun@$bunver"

        # Read-only preview of duplicate lockfile versions.
        ( cd "$d" && bun dedupe --dry-run 2>&1 | sed 's/^/    /' ) || true

        run_in "$d" bun dedupe
        run_in "$d" bun install
    done

    section "Untrusted postinstall scripts (bun >= 1.4 blocks them)"
    say "  Review per repo with: bun pm untrusted ; then: bun pm trust <name>"
    say "  Only trust packages that genuinely need a native build step."
}

cmd_reclaim_space() {
    section "Space recovery"
    say "  Before: $(df -h / | awk 'NR==2{print $4}') free on /"

    # Already-uninstalled apps: the caches outlive the .app.
    say ""
    say "  Brave (app removed, data left behind):"
    du_h "$HOME/Library/Application Support/BraveSoftware" "$HOME/Library/Caches/BraveSoftware"
    safe_rm "$HOME/Library/Application Support/BraveSoftware" "$HOME/Library/Caches/BraveSoftware"

    # Xcode leftovers: only CommandLineTools is installed (xcode-select -p).
    if [ ! -d /Applications/Xcode.app ]; then
        say ""
        say "  Xcode/Simulator leftovers (no Xcode.app installed):"
        du_h "$HOME/Library/Developer/Xcode" "$HOME/Library/Developer/CoreSimulator"
        safe_rm "$HOME/Library/Developer/Xcode" "$HOME/Library/Developer/CoreSimulator"
    else
        warn "Xcode.app present -- leaving ~/Library/Developer alone"
    fi

    say ""
    say "  Tool caches (all rebuild themselves):"
    du_h "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/prisma" \
         "$HOME/.cache/firebase" "$HOME/.cache/dfinity"
    safe_rm "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/prisma" \
            "$HOME/.cache/firebase" "$HOME/.cache/dfinity"

    if have brew; then
        say ""
        run brew cleanup --prune=all
        run brew autoremove
    fi

    if (( REMOVE_APPS )); then
        section "Remove Antigravity (flagged by --remove-apps)"
        du_h "$HOME/Library/Application Support/Antigravity" \
             "$HOME/Library/Application Support/Antigravity IDE" \
             "$HOME/Library/Caches/com.google.antigravity" \
             "$HOME/.antigravity" "$HOME/.antigravity-ide"
        safe_rm "/Applications/Antigravity.app" "/Applications/Antigravity IDE.app"
        safe_rm "$HOME/Library/Application Support/Antigravity" \
                "$HOME/Library/Application Support/Antigravity IDE" \
                "$HOME/Library/Caches/com.google.antigravity" \
                "$HOME/.antigravity" "$HOME/.antigravity-ide"
        say "  Chrome left installed on purpose (revisit in a week):"
        du_h "/Applications/Google Chrome.app" "$HOME/Library/Application Support/Google"
    else
        say ""
        dim "  Antigravity removal is opt-in: re-run with --remove-apps"
    fi

    if (( REMOVE_COLIMA )); then
        section "Remove colima (keeping OrbStack) -- flagged"
        du_h "$HOME/.colima"
        if have colima; then
            run colima delete -f
        fi
        safe_rm "$HOME/.colima"
    fi

    if (( REMOVE_TOOLCHAINS )); then
        section "Remove unused toolchains -- flagged"
        du_h "$HOME/.pyenv" "$HOME/.rvm"
        safe_rm "$HOME/.pyenv" "$HOME/.rvm"
        say "  MacPorts (/opt/local) kept: 'port' is still on your PATH."
    fi

    say ""
    say "  After (dry-run does not change this): $(df -h / | awk 'NR==2{print $4}') free on /"
}

cmd_git() {
    section "Git: permanent Keychain credentials + cheap caches"

    run git config --global --unset-all credential.helper
    run git config --global credential.helper osxkeychain

    local kv
    for kv in \
        feature.manyFiles=true \
        core.untrackedCache=true \
        core.commitGraph=true \
        gc.writeCommitGraph=true \
        fetch.writeCommitGraph=true \
        fetch.prune=true \
        diff.algorithm=histogram
    do
        run git config --global "$kv"
    done

    say ""
    say "  Migrating stored tokens into Keychain (one prompt per host):"
    local d
    for d in "$REPOS_DIR"/*/; do
        [ -d "${d}.git" ] || continue
        say "  -- $(basename "$d")"
        run_in "$d" git fetch --prune --quiet
    done

    say ""
    say "  Plaintext credential file:"
    if [ -f "$HOME/.git-credentials" ]; then
        du_h "$HOME/.git-credentials"
        if (( DELETE_CREDS )); then
            safe_rm "$HOME/.git-credentials"
        else
            say "  Left in place. Delete with: $0 git --delete-creds  (after fetches succeed)"
        fi
    else
        dim "  (already gone)"
    fi

    say ""
    say "  Skipped on purpose: core.fsmonitor (FSEvents-based; conflicts with the"
    say "  .fseventsd/no_log set on the Dev volume) and shared object pools."
}

cmd_zshrc() {
    local src="$HOME/.zshrc"
    [ -f "$src" ] || die "no $src"
    section "~/.zshrc cleanup (dedupe PATH lines, drop pnpm block, add bun cache)"

    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/zshrc.XXXXXX")"
    # ${tmp:-} matters: the RETURN trap fires after the local is unbound, and
    # `set -u` would otherwise abort the script right after a successful run.
    trap 'rm -f "${tmp:-}"' RETURN

    # State machine: drop the pnpm block *including* its case/esac, otherwise
    # removing only the export lines leaves an empty `case ... esac` and the
    # shell fails to parse the file at next login.
    awk '
        BEGIN { pnpm = 0 }
        $0 == "# pnpm"            { next }
        $0 == "# pnpm end"        { next }
        $0 ~ /^export PNPM_HOME=/ { pnpm = 1; next }
        pnpm == 1 {
            if ($0 == "esac") { pnpm = 0 }
            next
        }
        # Drop exact duplicates of non-empty, non-comment lines (keep first).
        $0 != "" && $0 !~ /^[[:space:]]*#/ {
            if (seen[$0]++ > 0) next
        }
        { print }
    ' "$src" > "$tmp" || die "awk rewrite failed"

    # Safety gate: the result must parse before it may replace the original.
    if have zsh; then
        if ! zsh -n "$tmp" 2>/dev/null; then
            bad "rewritten .zshrc does not parse -- leaving original untouched"
            say "  inspect: $tmp"
            exit 1
        fi
        ok "rewritten .zshrc parses (zsh -n)"
    fi

    if ! grep -q 'BUN_INSTALL_CACHE_DIR' "$tmp"; then
        printf '\n# bun package cache on the Dev volume (same volume as the repos,\n# so clonefile stays copy-on-write instead of falling back to copyfile)\nexport BUN_INSTALL_CACHE_DIR="%s"\n' "$BUN_CACHE_DIR" >> "$tmp"
    fi
    if ! grep -q 'ulimit -n' "$tmp"; then
        printf '\n# watchers/builds need more than the default 256 fds\nif [ "$(ulimit -n)" -lt 10240 ]; then ulimit -n 10240 2>/dev/null || true; fi\n' >> "$tmp"
    fi

    say ""
    diff -u "$src" "$tmp" | sed 's/^/  /' || true
    say ""
    if (( APPLY )); then
        local bak="$src.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$src" "$bak"
        say "  backup: $bak"
        cat "$tmp" > "$src"
        ok "installed new ~/.zshrc"
    else
        dim "  [dry-run] would back up to ~/.zshrc.bak.<timestamp> and install the above"
    fi
}

cmd_preflight() {
    section "Preflight for the Dev-volume cutover"

    local fail=0
    require_dev_dir

    say "repos:"
    local d name dirty
    for d in "$REPOS_DIR"/*/; do
        [ -d "${d}.git" ] || continue
        name="$(basename "$d")"
        # Untracked files (these two deliverables, for one) are harmless: they
        # move with the tree and are not work you can lose.
        dirty="$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$dirty" = "0" ]; then ok "$name clean"; else bad "$name has $dirty uncommitted change(s)"; fail=1; fi
    done

    say ""
    say "rebuild proof (node_modules -> bun.lock):"
    for d in "$REPOS_DIR"/*/; do
        [ -f "${d}bun.lock" ] || [ -f "${d}bun.lockb" ] || continue
        (( APPLY )) || { dim "  [dry-run] (cd $(basename "$d") && bun install --frozen-lockfile)"; continue; }
        if ( cd "$d" && bun install --frozen-lockfile >/dev/null 2>&1 ); then
            ok "install $(basename "$d")"
        else
            bad "install $(basename "$d")"; fail=1
        fi
    done

    say ""
    say "processes that must be quit before unmounting:"
    local pat hit
    for pat in 'Visual Studio Code.app/Contents/MacOS/Code' 'Arc.app/Contents/MacOS/Arc' 'Antigravity' 'OpenCode' 'dsh'; do
        hit="$(pgrep -f "$pat" 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$hit" = "0" ]; then ok "not running: $pat"; else bad "running ($hit): $pat"; fail=1; fi
    done
    say "  also run:  sudo lsof +D $DEV_DIR | head"
    say "  (nothing may be listed)"

    say ""
    say "backup on $PROD_HOST:"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$PROD_HOST" \
        "ls -d $PROD_BACKUP_ROOT-* 2>/dev/null || echo '  (none yet)'; du -sh $PROD_BACKUP_ROOT-* 2>/dev/null || true" \
        || warn "cannot reach $PROD_HOST"

    say ""
    say "volume state:"
    if mount | grep -qF " on $DEV_DIR "; then
        say "  already mounted at $DEV_DIR:"; mount | grep -F " on $DEV_DIR "
        ok "cutover already done"
    elif diskutil info Dev >/dev/null 2>&1; then
        local dev uuid
        dev="$(diskutil info Dev | awk -F': +' '/Device Node/{print $2}')"
        uuid="$(diskutil info Dev | awk -F': +' '/Volume UUID/{print $2}')"
        say "  volume 'Dev' exists at $dev, mount point: $(diskutil info Dev | awk -F': +' '/Mount Point/{print $2}')"
        say ""
        say "  Exact cutover commands (run with everything quit):"
        say "    sudo diskutil unmount /Volumes/Dev"
        say "    sudo mv $DEV_DIR ${DEV_DIR}.old"
        say "    sudo mkdir $DEV_DIR"
        say "    sudo mount -t apfs $dev $DEV_DIR"
        say "    sudo ditto ${DEV_DIR}.old $DEV_DIR"
        say "  then add to /etc/fstab (sudo vifs):"
        say "    UUID=$uuid $DEV_DIR apfs rw,nobrowse,noatime 0 0"
    else
        say "  volume 'Dev' does not exist yet. Create it with:"
        say "    diskutil apfs addVolume disk1 APFS Dev"
        say "  then re-run: $0 preflight"
    fi

    say ""
    if (( fail )); then bad "preflight has blocking issues"; else ok "preflight clean"; fi
    return "$fail"
}

cmd_post_volume() {
    require_dev_dir
    section "After the volume is mounted at $DEV_DIR"

    if ! mount | grep -qF " on $DEV_DIR "; then
        die "$DEV_DIR is not a mounted volume -- do not run this yet (see preflight)"
    fi
    ok "$DEV_DIR is a mounted volume"

    say ""
    say "daemon markers:"
    say "  mdutil: $(mdutil -s "$DEV_DIR" 2>&1 | tail -1)"
    [ -e "$DEV_DIR/.metadata_never_index" ] && ok ".metadata_never_index present" || bad ".metadata_never_index missing"
    [ -e "$DEV_DIR/.fseventsd/no_log" ] && ok ".fseventsd/no_log present" || bad ".fseventsd/no_log missing"

    say ""
    say "bunfig ($HOME/.bunfig.toml):"
    if [ -f "$HOME/.bunfig.toml" ] && grep -q -e 'BUN_CACHE_DIR' -e 'install.cache' "$HOME/.bunfig.toml" 2>/dev/null; then
        ok "cache config present"
    else
        if (( APPLY )); then
            [ -f "$HOME/.bunfig.toml" ] && cp -p "$HOME/.bunfig.toml" "$HOME/.bunfig.toml.bak.$(date +%Y%m%d-%H%M%S)"
            cat > "$HOME/.bunfig.toml" <<EOF
# Written by dev-optimize.sh. The cache lives on the Dev volume so Bun's
# clonefile() stays copy-on-write (it degrades to copyfile across volumes).
[install.cache]
dir = "$BUN_CACHE_DIR"
EOF
            ok "wrote ~/.bunfig.toml"
        else
            dim "  [dry-run] would write ~/.bunfig.toml -> [install.cache] dir = $BUN_CACHE_DIR"
        fi
    fi

    say ""
    say "moving the package cache onto the Dev volume:"
    if [ -d "$DEV_DIR/.cache/bun/install/cache" ]; then
        dim "  already in place"
    elif [ -d "$HOME/.bun/install/cache" ]; then
        run mkdir -p "$DEV_DIR/.cache/bun/install"
        run mv "$HOME/.bun/install/cache" "$BUN_CACHE_DIR"
    else
        dim "  nothing to move"
    fi

    say ""
    say "reinstalling node_modules from the cache on this volume:"
    local d
    for d in "$REPOS_DIR"/*/; do
        [ -f "${d}bun.lock" ] || [ -f "${d}bun.lockb" ] || continue
        run_in "$d" bun install --frozen-lockfile
    done

    if (( APPLY )); then
        : > "$DEV_DIR/.devvolume"
        ok "wrote $DEV_DIR/.devvolume marker"
    fi

    say ""
    say "Reminder: ~/.bun/install/global stays on the Data volume (it holds dsh)."
    say "Global installs therefore copy rather than clone -- per-command cost only."
}

cmd_verify() {
    section "Verification (read-only)"
    local fail=0
    local v

    local mounted=0
    if mount | grep -qF " on $DEV_DIR "; then
        mounted=1
        ok "volume mounted at $DEV_DIR"
        mount | grep -F " on $DEV_DIR " | sed 's/^/    /'
        mount | grep -F " on $DEV_DIR " | grep -q nobrowse || { warn "nobrowse not set"; }
    else
        bad "no volume mounted at $DEV_DIR"
        fail=1
    fi

    if (( mounted )); then
        v="$(mdutil -s "$DEV_DIR" 2>&1 | tail -1)"
        case "$v" in
            *disabled*) ok "Spotlight: $v" ;;
            *)          bad "Spotlight: $v"; fail=1 ;;
        esac

        [ -e "$DEV_DIR/.metadata_never_index" ] && ok ".metadata_never_index present" \
            || { bad ".metadata_never_index missing"; fail=1; }
        if [ -e "$DEV_DIR/.fseventsd/no_log" ]; then
            ok ".fseventsd/no_log present"
            local extra
            extra="$(ls -A "$DEV_DIR/.fseventsd" 2>/dev/null | grep -v '^no_log$' | wc -l | tr -d ' ')"
            [ "$extra" = "0" ] && ok "no fsevents journal files" || warn "$extra extra item(s) in .fseventsd"
        else
            bad ".fseventsd/no_log missing"; fail=1
        fi
    else
        say "  (skipping Spotlight / .fseventsd checks: nothing is mounted at $DEV_DIR yet)"
    fi

    if [ -f "$HOME/.bunfig.toml" ] && grep -q 'install.cache' "$HOME/.bunfig.toml"; then
        ok "~/.bunfig.toml has [install.cache]"
    else
        bad "~/.bunfig.toml missing [install.cache]"; fail=1
    fi

    local first_repo=""
    for v in "$REPOS_DIR"/*/; do
        [ -f "${v}package.json" ] && { first_repo="$v"; break; }
    done
    if [ -n "$first_repo" ]; then
        local cache; cache="$( cd "$first_repo" && bun pm cache 2>/dev/null | tail -1 )"
        if [ "$cache" = "$BUN_CACHE_DIR" ]; then ok "bun pm cache -> $cache"
        else bad "bun pm cache -> ${cache:-<empty>} (expected $BUN_CACHE_DIR)"; fail=1; fi
    fi

    if have pnpm; then bad "pnpm still on PATH: $(command -v pnpm)"; fail=1; else ok "pnpm removed from PATH"; fi

    local helper; helper="$(git config --global --get credential.helper 2>/dev/null || true)"
    [ "$helper" = "osxkeychain" ] && ok "git credential.helper=osxkeychain" \
        || { bad "git credential.helper=${helper:-<unset>}"; fail=1; }
    [ -f "$HOME/.git-credentials" ] && warn "plaintext ~/.git-credentials still present" \
        || ok "no plaintext ~/.git-credentials"

    say ""
    say "packageManager pins:"
    for v in "$REPOS_DIR"/*/; do
        [ -f "${v}package.json" ] || continue
        printf '  %-24s %s\n' "$(basename "$v")" \
            "$(grep -o '"packageManager": *"[^"]*"' "${v}package.json" 2>/dev/null || echo '(none)')"
    done

    say ""
    say "disk / memory:"
    df -h / | tail -1 | sed 's/^/  /'
    sysctl -n vm.swapusage | sed 's/^/  /'
    if [ -d "${DEV_DIR}.old" ]; then
        warn "${DEV_DIR}.old still exists ($(du -sh "${DEV_DIR}.old" 2>/dev/null | cut -f1)) -- the rollback copy"
    fi

    say ""
    if (( fail )); then bad "verification has failures"; else ok "all checks passed"; fi
    return "$fail"
}

require_dev_dir() {
    [ -d "$DEV_DIR" ] || die "DEV_DIR not found: $DEV_DIR (override with DEV_DIR=...)"
}

usage() {
    cat <<EOF
$0 -- macOS dev-workstation optimisation (dry-run by default)

Usage: $0 <command> [--apply] [flags]

Commands:
  backup              rsync ~/Dev (minus node_modules) + dotfiles to $PROD_HOST
  cleanup-toolchain   remove pnpm, npm/yarn caches, prune nvm
  bun-align           set packageManager=bun@$(bun -v 2>/dev/null || echo 1.x), dedupe, install per repo
  reclaim-space       delete caches left by removed apps, Xcode leftovers, brew cleanup
  git                 Keychain credential helper + cheap git caches
  zshrc               dedupe ~/.zshrc, drop pnpm block, add bun cache env
  preflight           check the machine is ready for the volume cutover
  post-volume         run AFTER the volume is mounted at $DEV_DIR
  verify              read-only verification of the whole setup
  help                this text

Flags:
  --apply               actually run mutations (default: print only)
  --remove-apps         reclaim-space also removes Antigravity (keeps Chrome)
  --remove-colima       reclaim-space also deletes the colima VM (~1.4 GB)
  --remove-toolchains   reclaim-space also deletes pyenv + RVM (keeps MacPorts)
  --delete-creds        git: delete ~/.git-credentials after fetches succeed
  --mode=tar|rsync      backup: one compressed stream (fast on many small files)
                        or per-file rsync (resumable, default)

Environment:
  DEV_DIR=$DEV_DIR
  PROD_HOST=$PROD_HOST
  PROD_BACKUP_ROOT=$PROD_BACKUP_ROOT

Examples:
  $0 verify
  $0 backup --apply
  $0 cleanup-toolchain --apply
  $0 bun-align --apply
  $0 zshrc --apply
  $0 preflight
EOF
}

main() {
    [ $# -gt 0 ] || { usage; exit 1; }
    local cmd="$1"; shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --apply)             APPLY=1 ;;
            --remove-apps)       REMOVE_APPS=1 ;;
            --remove-colima)     REMOVE_COLIMA=1 ;;
            --remove-toolchains) REMOVE_TOOLCHAINS=1 ;;
            --delete-creds)      DELETE_CREDS=1 ;;
            --mode=*)            BACKUP_MODE="${1#*=}" ;;
            --mode)              shift; BACKUP_MODE="${1:-}"; [ -n "$BACKUP_MODE" ] || die "--mode needs a value" ;;
            --help|-h)           usage; exit 0 ;;
            *) die "unknown flag: $1" ;;
        esac
        shift
    done

    case "$cmd" in
        backup)            cmd_backup ;;
        cleanup-toolchain) cmd_cleanup_toolchain ;;
        bun-align)         cmd_bun_align ;;
        reclaim-space)     cmd_reclaim_space ;;
        git)               cmd_git ;;
        zshrc)             cmd_zshrc ;;
        preflight)         cmd_preflight ;;
        post-volume)       cmd_post_volume ;;
        verify)            cmd_verify ;;
        help|--help|-h)    usage ;;
        *)                 usage; exit 1 ;;
    esac
}

main "$@"
