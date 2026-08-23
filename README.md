# Omarchy 4 on Arch Linux ARM — a UTM VM for Apple Silicon

A **native aarch64** virtual machine (HVF-accelerated, no emulation) running
Arch Linux ARM + Hyprland with the configuration, themes and tooling of
[Omarchy 4](https://omarchy.org) — built from macOS by a single script, with no
manual steps in the UTM interface.

![Desktop](shots/hires.png)

> 🇪🇸 The detailed guide and the write-up are in Spanish:
> **[EMPEZAR.md](EMPEZAR.md)** (how to run it) · **[ARTICULO.md](ARTICULO.md)**
> (why it is built this way) · **[README.es.md](README.es.md)**.
> This page has everything you need to get going.

## Why not just install Omarchy?

Not because it refuses to run — **because the packages do not exist**. Verified
against primary sources on 2026-08-23:

| Check | Result |
|---|---|
| `stable-mirror.omarchy.org/core/os/aarch64/core.db` | **404** (x86_64 → 200) |
| `install/post-install/pacman.sh` | overwrites `/etc/pacman.d/mirrorlist` with `stable-mirror.omarchy.org/$repo/os/$arch` |
| `omarchy.org/install-bare` | **404**, removed |
| `omacom-io/omarchy-iso` → `plans/aarch64-support.md` | ARM64 = **planned, not implemented** |

So the installer points pacman at a mirror with no aarch64 tree, and the first
`pacman -Syu` on ARM fails. The Omarchy tree itself is architecture-agnostic:
it's shell, Lua and QML.

**A correction worth making**, because it is repeated a lot: Omarchy 3.x had an
explicit architecture guard — `install/preflight/guard.sh`, line 25,
`[[ $(uname -m) != "x86_64" ]] && abort`. **Quattro does not.** The `preflight/`
directory is gone and `uname -m` appears **zero times** in the whole branch. The
blocker moved from "it refuses" to "there is no repo to install from", which is
a much smaller problem — and one that publishing ~25 aarch64 packages would
close.

This project builds the equivalent base — Arch Linux ARM + Hyprland — and
applies the **actual contents** of the Omarchy repository on top.

## The trap: the default branch is `quattro`, not `master`

`git clone` of `basecamp/omarchy` does **not** give you `master` (3.8.5) but the
default branch **`quattro`** (4.x). They are different products:

| | `master` (3.8.5) | `quattro` (4.x) |
|---|---|---|
| Bar | waybar | **quickshell** (`omarchy-shell`) |
| Hyprland config | `.conf` | **Lua** (`hyprland.lua`, `bootstrap.lua`) |
| Distribution | scripts in `~/.local/share` | **pacman package** in `/usr/share/omarchy` |

Since that pacman package is x86_64-only, copying just the dotfiles leaves
`OMARCHY_PATH` empty → `bashrc` fails → Hyprland cannot find `bootstrap.lua` →
**it boots into emergency mode**. `stage3.sh` reproduces by hand what the
package would have done.

Most existing guides for Apple Silicon target **Omarchy 3.x**. This one targets 4.

## Or skip the build

The image this produces is on the Internet Archive, sanitised and ready to
import — no build, no Homebrew, no waiting:

**https://archive.org/details/omarchy-arm-utm** · 6.5 GB · `sha256 9d6afb16843bd868…`

```bash
shasum -a 256 -c omarchy-arm-utm.zip.sha256
unzip omarchy-arm-utm.zip
open "Omarchy ARM.utm"
```

User `omarchy`, password `omarchy` (also root) — **change it with `passwd`**.

## Quick start (build it yourself)

```bash
git clone https://github.com/ggalancs/omarchy-arm-utm.git
cd omarchy-arm-utm
./build-omarchy-arm.sh
```

Requirements: **Apple Silicon Mac**, Homebrew, **UTM 4.7+**, Xcode Command Line
Tools (for `git` and `python3`), **~40 GB free**. No `sudo` needed — the script
touches nothing outside its own working directory.

It asks six questions, all pre-filled from your Mac (timezone from
`/etc/localtime`, keyboard from macOS preferences, cores and RAM from `sysctl`),
so Enter accepts everything. Add `--yes` to skip the questions entirely; with no
tty it never asks.

**The script is a single self-contained file.** It embeds the twelve files it
needs — three install stages, the sanitiser, the repair harness, the optional-app
installer, the post-update hook, the VM config, two `expect` harnesses, the QEMU
launcher and the `.utm` bundle writer — and writes them out at startup. You can
copy just that file to another Mac.

### How long

Measured on an M3 Max, tools compiled, without OBS/Pinta:

| Phase | | Time |
|---|---|---|
| `deps` | host checks, installs qemu/expect/aria2 | ~10 s |
| `fetch` | Alpine ISO + ALARM rootfs, sha256 and MD5 verified | 2 min |
| `prepare` | package list, computed against Omarchy's live branch | ~10 s |
| `build` | Alpine headless → partition → rootfs → three chroot stages | **40 min** |
| `utm` | writes the `.utm` bundle and registers it | 1 min |
| `verify` | boots and checks *inside the guest* that the desktop is up | 4 min |
| `sanitize` | copies the disk and strips identity, for distribution | 10 min |
| `package` | compacts the qcow2, builds the bundle, zips it | 3 min |

**~57 minutes total** → a 4.1 GB `.zip`; peak 21 GB on disk. Including OBS
Studio and Pinta adds ~50 minutes (OBS compiles from source).

Every phase is resumable: `--from build`, `--only package`, `--list`.

## What you get

- **Arch Linux ARM** aarch64, `linux-aarch64` kernel, btrfs with `@` / `@home`
  subvolumes, zstd compression, 1 GiB ESP, systemd-boot
- **Hyprland 0.56.1** with the full Omarchy 4 stack: quickshell (bar, menu, OSD
  *and* notification daemon), hyprlock, hypridle, hyprsunset, uwsm,
  xdg-desktop-portal-hyprland, SDDM with autologin and the Omarchy theme
- Dotfiles, themes and the **~435 `omarchy-*` commands**
- **17 Omarchy tools built for aarch64** that upstream does not ship for ARM:
  `tensaku`, `omacalc`, `omacut`, `omawrite`, `aether`, `cliamp`, `ttfx`,
  `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`, `ttf-ia-writer`,
  `hyprland-preview-share-picker`, `xdg-terminal-exec`, `tobi-try`,
  `ufw-docker`, `yay`
- Optionally **OBS Studio** (no browser plugin — its CEF is x86-only) and
  **Pinta** (on Microsoft's official arm64 .NET)
- `qemu-guest-agent` and `spice-vdagent` for host integration
- **`omarchy-update` works**, with a post-update hook that keeps the Omarchy
  checkout in sync and snapper snapshots before each update

Of the 148 packages in `omarchy-base.packages`, **123 exist in Arch Linux ARM**;
17 of the 25 missing are built from source.

## What does not work

- **No GL acceleration inside the VM.** Under virtio-gpu, GPU clients map but
  never paint; only `wl_shm` clients render. Fixed with
  `LIBGL_ALWAYS_SOFTWARE=1`, so blur and shadows are disabled. Fine for normal
  use, not for video or 3D.
- **Resolution is fixed at boot** (1920x1200 by default, editable in
  `~/.config/hypr/monitors.lua`). Changing the mode at runtime whites out the
  screen under virtio-gpu.
- **`herdr` is missing** — it needs Zig 0.15 and Arch Linux ARM only packages
  0.16.
- Single monitor.

## Keyboard on a Mac

macOS grabs Cmd before UTM sees it, so the VM ships with Alt and Super swapped
via `altwin:swap_lalt_lwin`:

| Mac key | In the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

⌥+Space opens the Omarchy menu, ⌥+Return a terminal, ⌥+K the full keybinding list.

## Proprietary apps

1Password, Obsidian, Typora, LocalSend and Google Chrome are **not** in the
image — not because they do not work (they all have official ARM64 builds) but
because shipping them would mean redistributing third-party binaries. The image
carries an installer that fetches them from their official source, on your
machine:

```bash
omarchy-arm-extras --list
omarchy-arm-extras            # interactive menu
omarchy-arm-extras --all      # everything missing
```

Spotify has no native ARM client, but the web app works — it needs Widevine,
which ships inside Google Chrome arm64 (`omarchy-arm-extras chrome spotify-web`).

## Things that were hard to find

- **The ESP is mounted after extracting the rootfs.** The ALARM tarball has
  symlinks in `/boot` and vfat cannot hold them.
- **`bootctl install --no-variables`.** The build VM's NVRAM does not travel to
  UTM, so booting relies on the fallback path `\EFI\BOOT\BOOTAA64.EFI`.
- **The `.utm` bundle is written by hand.** `utmctl` cannot create VMs and UTM
  only scans `Documents/` at app launch. `config.plist` needs all **ten**
  top-level keys — they are decoded with `decode()`, not `decodeIfPresent()`.
- **The VARS half of aarch64 UEFI is `edk2-arm-vars.fd`**, not
  `edk2-aarch64-vars.fd` (which does not exist).
- **Seal Omarchy's migrations.** A normal installer marks them all on
  completion; without that, `omarchy-update` replays ~80 historical migrations
  and dies on the first x86-only package.
- **`grep -r` does not see symlink targets.** After renaming the build user, a
  text sweep reported zero matches while **439 links dangled** — including all
  431 `omarchy-*` commands. Use `find -type l -lname`.
- **A distro's package list is a claim about its architecture.** Filling gaps
  from memory of the previous version reintroduced `mako`, `swayosd`, `walker`
  and `elephant`, which Omarchy 4 deliberately retires — and `mako` steals
  `org.freedesktop.Notifications` from the shell over D-Bus.
- **A success message that depends on nothing.** With `set -uo pipefail` and no
  `-e`, four of the eight phases were structurally incapable of failing.

The full write-up, including the audit that found 37 defects in this very
script, is in [ARTICULO.md](ARTICULO.md) (Spanish).

## Prior art, and where this fits

This is not the only attempt, and for bare-metal Apple Silicon it is not the
best one. Verified 2026-08-23:

| Project | Target | |
|---|---|---|
| [omarchy-mac/omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) | **Omarchy 4 on Asahi Alarm, M1/M2 bare metal**, one command, LUKS | 896★, active |
| [omarchy-mac/omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64) | The aarch64 pacman repo that upstream doesn't publish | the missing piece |
| [jondkinney/armarchy](https://github.com/jondkinney/armarchy) | Omarchy **3.x** on Asahi and VMs | 33★ |
| [Linux-for-Fydetab-Duo/imagebuild](https://github.com/Linux-for-Fydetab-Duo/imagebuild) | Omarchy 4 on RK3588S hardware | new |

**If you have an M1 or M2 and want Omarchy on the metal, use omarchy-mac.** It
is more mature than this and it gives you a real GPU.

This project covers what that one cannot:

- **M3, M4 and whatever comes next.** Asahi's installer supports M1 and M2 only;
  M3 is work in progress and M4 is not started. A VM works on any of them.
- **Keeping macOS untouched.** No partitioning, no reduced-security boot.
- **External monitors.** Asahi still lists USB-C displays and Thunderbolt as
  unsupported; in a VM the host handles the screens.

The trade is the one stated above: no GPU acceleration inside the VM.

## Layout

```
build-omarchy-arm.sh   the autonomous builder, with everything embedded
EMPEZAR.md             how to run it (ES) — requirements, timings, troubleshooting
ARTICULO.md            how it was figured out (ES)
provision/src/         stage1..3.sh, repair.sh, sanitize.sh, omarchy-arm-extras, hooks/
scripts/               qemu, expect harnesses, .utm bundle writer
fixes/                 the 17 corrections found along the way, as a record
dist/LEEME.md          the README that ships inside the image (ES)
```

## Status

Validated by a full from-scratch run: 8/8 phases, 17/17 tools built, guest-side
verification returning a verdict, resulting image booting to a themed desktop.

## Licence

[MIT](LICENSE) for this repository's code. Omarchy, Arch Linux ARM, Hyprland and
the rest keep their own. Unofficial work, unaffiliated with Basecamp or the
Omarchy project. Omarchy supports x86_64; when the aarch64 ISO they already have
planned ships, this stops being necessary.
