# macOS Dev Workstation Runbook

Machine: `MacBookPro15,2` (2018 13", Intel, 8 threads) · macOS 15.8.1 · 8 GB RAM · 500 GB single APFS container.

This runbook is the human-facing companion to [`scripts/macos/dev-optimize.sh`](../scripts/macos/dev-optimize.sh). The script is **dry-run by default**; every step below shows the command it will run with `--apply`.

> These two files are intentionally left **untracked** in `dejis-cloud-infra`. This repo is server infrastructure, not machine setup. Move them to a dotfiles repo when convenient.

## Status

| Phase | State |
|---|---|
| 1. Backup to prod | **Deferred by request.** A transfer was started and cancelled; the partial archive was removed from `dejis-cloud`. **There is currently no backup of `~/Dev`.** |
| 2–4. Toolchain / git / space | Not run |
| 5. Dev volume cutover | Not started |
| 6. Memory / thermal / power | Not started |

Consequence of deferring Phase 1: the 20 `.env*` files and every repo still exist **only on this machine**, and there is no Time Machine destination. The volume cutover in Phase 5 keeps `Dev.old` as a same-disk rollback, but same-disk is not a backup — a failed drive loses both copies. Re-run Phase 1 before the cutover if you can.

## 0. Why any of this

| Measurement | Value |
|---|---|
| `~/Dev` | 3.9 GB but **206,882 files — 196,387 (95%) in `node_modules`** |
| Free space | 116 GiB of 466 GiB — space is *not* the bottleneck |
| RAM | 8 GB, **swap 2.8 GB of 4.1 GB used** at scan time, compressor holding 1.7 GB (swap resizes dynamically — a later reading was 872 MB of 2 GB after Spotify was closed) |
| Battery | **"Service Recommended"**, 1116 cycles, 2970 mAh (~58% of new) |
| Dead caches | ~60 GB (pnpm ~22 GB, npm 6.3 GB, Brave 5.4 GB, antigravity/Xcode/pyenv/MacPorts/colima) |

So: the APFS volume is worth doing because 196k disposable files are being fed to Spotlight and the fsevents journal — but it is a **second-order** optimisation. The first-order wins are memory (Phase 6) and the battery.

### Corrections to the common advice

1. A new volume in the **same container** gives zero space and zero I/O isolation — APFS volumes share one free-space pool. It buys a *policy boundary*.
2. `mdutil -E` on a fresh volume is a no-op. There is nothing to erase yet.
3. `.fseventsd/no_log` stops the **on-disk journal**, not live event delivery. VS Code/Metro/`tsc --watch` still receive events; per-tool `watcherExclude` is what reduces watcher CPU.
4. Bun uses **`clonefile`** (copy-on-write) on macOS, not hardlinks. Across volumes it silently falls back to `copyfile` (slower, full second copy). Cache and repos must live on the same volume.
5. Git has **no** global object cache. "Permanent git cache" means Keychain credentials plus per-repo caches (commit-graph, untracked cache).
6. `sudo` is unavailable to the coding agent on this machine, so every privileged step below is yours to run.

## 1. Backup `~/Dev` to the prod server

```bash
cd /Users/mac/Dev/Repos/dejis-cloud-infra
./scripts/macos/dev-optimize.sh backup --apply --mode=tar
```

**Use `--mode=tar`.** Measured on this link: per-file rsync averaged **~4.4 MB/min** across the 10,479 small files, while a single compressed stream moved **~58 MB/min** — the bottleneck is rsync's per-file round trips, not bandwidth (one large file reached 23.8 MB/s even under rsync). A ~700 MB tree goes from hours to minutes.

What it does:

```bash
tar -czf - -C /Users/mac/Dev --exclude 'node_modules' --exclude '.DS_Store' . \
  | ssh root@dejis-cloud 'mkdir -p /root/dev-backup-$(date +%F) && cat > .../dev.tar.gz'
tar -czf - .zshrc .zprofile .gitconfig .npmrc | ssh root@dejis-cloud 'cat > .../dotfiles.tar.gz'
```

Trade-off: one stream cannot resume — if it dies, re-run from scratch (cheap at this size). `--mode=rsync` stays available and is the default when you want resumability plus `-aHAX` per-file metadata fidelity. Both modes verify on the remote side.

**Gate:** `archive files` equals the local `find \( -type f -o -type l \)` count, and `archive .env` equals the local count (**20** `.env*` files at scan time). If they differ, stop.

Restore:

```bash
ssh root@dejis-cloud 'cat /root/dev-backup-*/dev.tar.gz' | tar -xzf - -C ~/Dev
```

> This is a pre-migration copy, not a backup strategy: one destination, one copy, same class of hardware. Real backups (Time Machine + an offsite copy) remain an open item. You already have R2 wired for Postgres dumps; the dev archive could ride the same pattern later.

## 2. Bun-only toolchain

```bash
./scripts/macos/dev-optimize.sh cleanup-toolchain --apply
./scripts/macos/dev-optimize.sh bun-align --apply
./scripts/macos/dev-optimize.sh zshrc --apply
```

`cleanup-toolchain`:

- `npm uninstall -g pnpm`, `rm -rf ~/Library/pnpm ~/Library/Caches/pnpm` (**~22 GB**). pnpm's globals (`pm2`, `repomix`, `wrangler`, `pnpm`) go with it — `pm2` has zero references anywhere in the repos, and the other two are `bunx` calls now.
- `npm cache clean --force`, `rm -rf ~/.npm` (**6.3 GB**). **npm and npx stay installed** — they are a few MB and `glorious-eagles` calls `npx only-allow bun` (corrected to `bunx` below).
- `brew uninstall yarn`, `rm -rf ~/Library/Caches/Yarn ~/.yarnrc` (~750 MB).
- nvm: keep `v22.22.3` + `v26.6.0`, uninstall the five v18.x and `v20.11.1`.
- `corepack disable`, `rm -rf ~/.cache/node/corepack`.
- Untouched: `~/.npmrc` (registry + `allow-scripts`) and `~/.bun/install/global` — **`dsh` lives there**.

`bun-align` (installed bun is **1.4.3**; three repos pin 1.4.0/1.4.2, three have no pin):

```bash
bun pm pkg set packageManager=bun@1.4.3   # bun never rewrites this on install
bun dedupe --dry-run                      # review duplicate lockfile versions
bun dedupe                                # real dedupe: re-resolves and installs
bun install
```

`glorious-eagles` only: change `"preinstall": "npx only-allow bun"` → `"bunx only-allow bun"` (or delete it — everything is bun now).

Deliberately **not** in the default path: `bun update --latest`. That is a breaking-change pass; do it per repo, on purpose, with a build afterwards.

Check postinstall blocking at any time:

```bash
bun pm untrusted     # what bun 1.4 refused to run
bun pm trust <pkg>   # only where a native build is genuinely required
```

## 3. Git

```bash
./scripts/macos/dev-optimize.sh git --apply            # repeat fetches if prompted
./scripts/macos/dev-optimize.sh git --delete-creds     # only after every fetch worked
```

- `credential.helper` moves from `store` to **`osxkeychain`**. All seven remotes are HTTPS GitHub; the token currently sits in plaintext in `~/.git-credentials`.
- Cheap speed config: `feature.manyFiles`, `core.untrackedCache`, `core.commitGraph`, `gc.writeCommitGraph`, `fetch.writeCommitGraph`, `fetch.prune`, `diff.algorithm=histogram`.
- **Skipped on purpose:** `core.fsmonitor` (FSEvents-based — you are about to disable the fsevents journal on that volume, and a restarted daemon would silently re-scan) and shared object pools (each `.git` is ≤77 MB).
- `git maintenance register` per repo is optional and marginal at these sizes.

## 4. Space

```bash
./scripts/macos/dev-optimize.sh reclaim-space --apply
# opt-in extras, each reversible:
./scripts/macos/dev-optimize.sh reclaim-space --apply --remove-apps
./scripts/macos/dev-optimize.sh reclaim-space --apply --remove-colima
./scripts/macos/dev-optimize.sh reclaim-space --apply --remove-toolchains
```

Default pass: Brave leftovers (**5.4 GB**, app already uninstalled), Xcode/Simulator leftovers (**4 GB** — only CommandLineTools is installed), pip/uv/prisma/firebase/dfinity caches (~2.5 GB), `brew cleanup --prune=all`, `brew autoremove`.

Already done: Spotify (app **and** its 16 GB `PersistentCache`) is gone — nothing to do.

Optional flags: Antigravity + its caches (~1.4 GB; Chrome is left installed on purpose — revisit in a week), colima VM (1.4 GB, not running), pyenv + RVM (1.6 GB; both unused — pyenv isn't even on `PATH`). MacPorts stays until you confirm `port` is dead.

Not bought back: `hibernatemode`. Keep `3`. On a battery Apple says is failing, safe sleep is the feature you want.

## 5. The Dev volume — cutover runbook

Goal: volume **Dev** in container `disk1`, mounted at **`/Users/mac/Dev`** so every path stays byte-identical (IDE recents, Mutagen sessions, DSH workspace, absolute paths inside build caches).

Fallback if the boot mount proves flaky: mount at `/Volumes/Dev` and symlink `~/Dev` → it. A failed mount then leaves a *dangling symlink* (loud) instead of a silently empty directory.

### 5.1 Preflight

```bash
./scripts/macos/dev-optimize.sh preflight
```

It checks: every repo clean, every repo rebuildable (`bun install --frozen-lockfile`), no VS Code/Arc/Antigravity/OpenCode/DSH running, the prod backup exists, and whether the volume exists yet.

Also, manually:

```bash
sudo lsof +D /Users/mac/Dev | head      # must print nothing
```

### 5.2 Create the volume

```bash
diskutil apfs addVolume disk1 APFS Dev
diskutil info Dev | grep -E 'Device Node|Volume UUID'
```

Record both. The device node will be `disk1s7`-ish — never hardcode it from this document.

### 5.3 Shrink the copy (optional but recommended)

```bash
cd /Users/mac/Dev/Repos && for d in */; do (cd "$d" && bun install --frozen-lockfile >/dev/null && echo "OK $d"); done
rm -rf /Users/mac/Dev/Repos/*/node_modules     # 3.9 GB -> ~0.6 GB to move
```

Every repo must print OK first — that is what makes deleting `node_modules` safe. Re-run `backup --apply` afterwards so the archive reflects the slim tree.

### 5.4 Quiesce

Quit **VS Code, Arc, OpenCode, Antigravity, every Terminal window, and DSH**. DSH's own workspace is inside the tree being moved; an unmount under it fails `EBUSY` and a half-copied tree is the worst outcome.

```bash
sudo lsof +D /Users/mac/Dev | head     # empty = safe
```

### 5.5 Mount at the final path and copy

```bash
sudo diskutil unmount /Volumes/Dev
sudo mv /Users/mac/Dev /Users/mac/Dev.old
sudo mkdir /Users/mac/Dev
sudo mount -t apfs /dev/disk1sX /Users/mac/Dev
sudo ditto /Users/mac/Dev.old /Users/mac/Dev
```

Use `ditto`, never `cp -r`/`mv`: it preserves ACLs, xattrs and hardlinks. `rsync` here would need `-aHAX` and still risks `.git` xattrs.

### 5.6 Verify before trusting it — mandatory gate

```bash
find /Users/mac/Dev.old -type f | wc -l
find /Users/mac/Dev     -type f | wc -l          # must be equal
ls -l /Users/mac/Dev/Repos/*/.env*               # secrets present
for d in /Users/mac/Dev/Repos/*/; do git -C "$d" fsck --no-progress >/dev/null && echo "fsck OK $d"; done
ls -ld /Users/mac/Dev                            # owner must be mac, not root
```

**Any mismatch → 5.10 rollback, do not continue.**

### 5.7 Make the mount survive reboot

```bash
sudo vifs
```

Add exactly one line (substitute the UUID from 5.2):

```
UUID=<Volume UUID> /Users/mac/Dev apfs rw,nobrowse,noatime 0 0
```

Then `sudo shutdown -r now`, and after boot:

```bash
mount | grep ' /Users/mac/Dev '
df -h /Users/mac/Dev
```

Expected: the volume at `/Users/mac/Dev`, with `nobrowse`. If `noatime` is absent from the option list, remove it from the fstab line — it is an optimisation, not a requirement. If the volume mounted at `/Volumes/Dev` instead, the fstab line is wrong: fix it, or switch to the symlink fallback.

Never add `noexec` — it breaks every `node_modules/.bin` shim.

### 5.8 Daemon exclusions

```bash
sudo touch /Users/mac/Dev/.metadata_never_index
sudo mkdir -p /Users/mac/Dev/.fseventsd
sudo touch /Users/mac/Dev/.fseventsd/no_log
sudo chown -R root:wheel /Users/mac/Dev/.fseventsd
sudo mdutil -i off -d /Users/mac/Dev
sudo mdutil -E /Users/mac/Dev
```

Then commit them by remounting:

```bash
sudo diskutil unmount /Users/mac/Dev
sudo mount -t apfs /dev/disk1sX /Users/mac/Dev
mdutil -s /Users/mac/Dev                 # => Indexing disabled.
sudo ls -la /Users/mac/Dev/.fseventsd    # => only no_log
```

Belt and braces: also add the volume in **System Settings → Siri & Spotlight → Spotlight Privacy**.

### 5.9 Repopulate and repoint bun

```bash
cd /Users/mac/Dev/Repos
for d in */; do [ -f "$d/bun.lock" ] && (cd "$d" && bun install --frozen-lockfile && echo "OK $d"); done
```

Then:

```bash
./scripts/macos/dev-optimize.sh post-volume --apply
./scripts/macos/dev-optimize.sh verify
```

`post-volume` writes `~/.bunfig.toml`:

```toml
[install.cache]
dir = "/Users/mac/Dev/.cache/bun/install/cache"
```

moves `~/.bun/install/cache` there, reinstalls each repo, and writes the `.devvolume` marker. The `[install.cache]` form is authoritative because GUI-launched processes never read `.zshrc`; the `BUN_INSTALL_CACHE_DIR` export added to `.zshrc` uses the same value so they can never disagree.

**Reinstalling is not optional.** `ditto` materialised the copy-on-write clones as full physical copies; only a fresh install from a cache *on the same volume* restores `clonefile` efficiency. Otherwise `node_modules` silently doubles.

### 5.10 Rollback

```bash
sudo diskutil unmount /Users/mac/Dev
sudo rmdir /Users/mac/Dev
# remove the /etc/fstab line (sudo vifs)
sudo mv /Users/mac/Dev.old /Users/mac/Dev
sudo diskutil apfs deleteVolume Dev
```

Keep `Dev.old` for one week, then `sudo rm -rf /Users/mac/Dev.old`.

When you set up Time Machine, exclude the rebuildable parts of the new volume:

```bash
tmutil addexclusion -p /Users/mac/Dev/.cache
```

## 6. Memory, thermal, power

These are the changes you will actually feel. Measured with `vmmap -summary` (root-owned processes are invisible to the agent — `sudo`, `ps` and `top` are all blocked).

| Process | Procs | Physical footprint |
|---|---|---|
| **VS Code** (33 extensions, 1.1 GB extension dir) | 17 | **2.7 GB** |
| **Arc** | 17 | **1.9 GB** |
| **postgres@18** (local brew service) | 9 | **586 MB** |
| MTLCompilerService (Metal shaders, spawned by Electron) | 8 | 220 MB |
| OpenCode | 4 | 94 MB |
| stale `biome lsp-proxy` from `sentinel-v2/node_modules` | 2 | 48 MB |
| Spotlight Metadata workers | 7 | 43 MB |
| Safari | 6 | 36 MB |

VS Code + Arc alone are **4.6 GB of 8 GB**. System-wide at scan time: 2.6 GB wired, 1.7 GB in the compressor, swap 2.8 GB of 4.1 GB (it had already fallen to 872 MB of 2 GB by the next reading — swap is dynamic, so compare like with like).

Ordered kill list:

1. **VS Code** — quit when not actively coding; trim to the extensions you use (`code --status` prints each extension host's cost). Biggest single lever.
2. **Arc** — fewer tabs, turn on auto-archive.
3. **`brew services stop postgresql@18`** when not doing DB work. Do **not** uninstall: it is genuinely used (18 references to `localhost:5432`, 13 to `/var/run/postgresql`).
4. Kill the stale biome pair: `pkill -f 'sentinel-v2/node_modules/.bun/@biomejs'`.
5. Antigravity/OpenCode: remove if unused (Phase 4).

Then:

```bash
sudo pmset -a powernap 0        # background wake churn on AC; keep hibernatemode 3
brew install --cask macs-fan-control
```

Macs Fan Control: **Custom** preset → sensor **"CPU Core Average"** (fallback "CPU PECI") → ramp from **50 °C**, full speed by **95 °C**, autostart at login. Sanity check under load:

```bash
pmset -g therm     # CPU_Speed_Limit below 100 = thermally limited
```

**Battery: get it replaced.** 1116 cycles, 2970 mAh, "Service Recommended". This is the one thing software cannot fix; a failing battery throttles sustained builds and can shut the machine down under load. Until it is replaced, do sustained work on AC.

UI and housekeeping (GUI-only items are marked):

```bash
defaults write com.apple.universalaccess reduceTransparency -bool true
defaults write com.apple.universalaccess reduceMotion -bool true
defaults write -g NSAutomaticWindowAnimationsEnabled -bool false
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
```

- GUI: browser **Memory Saver** on, "continue running background apps" off, in whichever browser survives.
- GUI: audit login items — Google Keystone ×2 + `GoogleUpdater.wake`, FDM, `iMusicHelper`, Mutagen, watchman (no daemon running; only matters for RN/Expo), and whether `postgresql@18` should auto-start.
- `ulimit -n 10240` is added by `zshrc --apply` (65535 usually exceeds `kern.maxfilesperproc`).
- **FileVault is OFF** on a laptop holding cloud credentials. Enable it after the migration soak (T2 hardware encryption; negligible I/O cost).

## 7. Acceptance

```bash
./scripts/macos/dev-optimize.sh verify
```

Passes when: volume mounted at `/Users/mac/Dev` with `nobrowse`; `~/Dev` survives a reboot; `mdutil -s` says Indexing disabled; `.fseventsd` contains only `no_log`; `bun pm cache` points at the Dev volume; `pnpm` is gone from `PATH`; `git credential.helper=osxkeychain` with no plaintext `~/.git-credentials`; every repo installs and `git status` is clean; `dsh` starts from `/Users/mac/Dev/Repos/dejis-cloud-infra`.

## 8. Defaults chosen for you (override at any time)

1. Antigravity apps + caches removed (opt-in flag); **Chrome kept** for now.
2. `colima` deleted, OrbStack kept (both opt-in flags).
3. pyenv + RVM removed; **MacPorts kept**.
4. `postgresql@18` kept installed, service stopped when idle.
5. `npx only-allow bun` → `bunx`; npm/npx binaries kept.
6. `hibernatemode 3` kept; FileVault enabled after the soak.
7. Volume mounted at `/Users/mac/Dev` via `/etc/fstab`; symlink fallback only if the reboot test fails.
