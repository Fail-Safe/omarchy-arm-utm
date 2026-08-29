# Which file should I download?

**`omarchy-arm-utm-v2.zip`** — smaller, and everything works.

| | `omarchy-arm-utm-v2.zip` | `omarchy-arm-utm.zip` |
|---|---|---|
| | **← download this one** | the first release |
| Size | 3.6 GB (3.8 GB unpacked) | 6.5 GB (13 GB unpacked) |
| Published | 2026-08-29 | 2026-08-23 |
| Shared clipboard | **works, verified both ways** | does not work |
| "Update System" notification | gone | repeats on every boot |
| "Reboot?" after each update | gone | repeats forever |
| `sshd` | disabled | enabled, with a trivial password |
| `sha256` | `81b64fcc6b065953a685cb7a0e6e2a3b49227b6c77c541362c25e5db86c66f1b` | `9d6afb16843bd868c9503dbfdaaa5f1ff7634b23f9a972b344ec27ca0a795fb4` |

The plain name belongs to the first release and keeps it, so links and checksums
published back in August still resolve to the exact bytes they were written
for. That is the only reason the better file is the one with `-v2` in its name.

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

User `omarchy`, password `omarchy` (also root). **Change it with `passwd`.**

Arch Linux ARM aarch64 · Hyprland 0.56.1 · the Omarchy 4 desktop · 442
`omarchy-*` commands · 17 tools built for ARM · OBS Studio and Pinta.

## What changed on 2026-08-29

- **The VM is now called `Omarchy 4 ARM64`** when you import it, instead of
  `Omarchy ARM`. The old name carried no version, which would say nothing the
  day Omarchy 5 lands, and it did not match the name the UTM gallery announces.

- **The mouse behaves like a mouse again.** Two releases ago the clipboard fix
  passed `-f` to `spice-vdagentd` believing it meant "foreground". It does not
  — that is `-x`, which was already there. `-f` is `--fake-uinput`: the daemon
  skips the ioctls that set up `/dev/uinput` and then fails on every write
  (`write /dev/uinput: Invalid argument`, eight times per boot). The agent still
  announced itself, so UTM stopped grabbing the pointer, but nothing replaced
  the grab. The flag is gone, and the `-X` the clipboard does need now travels
  through `/etc/conf.d/spice-vdagentd`, the extension point Arch's own unit
  already reads. If you are on an affected image, `fixes/19-portapapeles.sh`
  undoes it in place.
- **All 17 tools now build.** `herdr` was the one that never did; it now comes
  from Omarchy's own PKGBUILD, which declares `aarch64` and fetches the official
  Zig 0.15.2 instead of relying on the version the repos happen to ship. Its
  desktop shortcuts stop being dead links.
- **No orphaned packages.** The image used to ship three (`asio` and two
  `linux-firmware-*` for hardware a VM does not have), so the very first
  `omarchy-update` greeted you with a prompt about them. They are gone.

## What changed on 2026-08-26

The newer file was rebuilt. Same desktop, same size; what changed is what the
image no longer carries and what was proven about it:

- **`sshd` comes disabled.** The previous build left it listening with
  `omarchy`/`omarchy`. Enable it yourself if you want it:
  `sudo systemctl enable --now sshd`.
- **No trace of the build account.** The bundle is named `Omarchy 4 ARM64.utm`
  instead of carrying an internal version number, `ttfx` no longer has the
  build path compiled into it, and files whose *name* mentioned the build user
  are gone.
- **The preferred terminal points at something that exists.** It named
  `Alacritty.desktop`, which is not in the image; it now lists what is.
- **A udev rule was removed** that handed the session user access to the port
  `spice-vdagentd` owns exclusively — it did nothing useful and could take the
  daemon's channel away.
- **The clipboard was verified with real data**, both directions, on a VM
  booted in UTM — not inferred from the pieces being in place.

## What the newer file fixes

- **Shared clipboard, both ways.** Text only. Needs "Share clipboard" enabled in
  UTM, and the VM **open as a window**: started headless there is no SPICE
  client attached, so the channel exists but carries nothing. The first release
  could not do this at all — `spice-vdagentd` only honours clipboard traffic
  from the agent it considers to be in the active seat0 session, which SDDM +
  Hyprland never satisfied, and the stock session agent is an X11 program with
  no Wayland selection to take.
- **Shared folders.** Pick one in *VM Settings → Sharing*, then run
  `omarchy-arm-share` in the guest — it handles both VirtFS and SPICE WebDAV.
- **Two notifications that never went away.** "Update System" on every boot (the
  six user `.service` files were never installed, so first-run never completed),
  and "Linux kernel has been updated. Reboot?" after every update (Omarchy looks
  for a package-owned `/usr/lib/modules/<ver>/vmlinuz`; `linux-aarch64` puts the
  image in `/boot/Image` and ships none, so the check can never pass).
- **45% smaller** — 675 MB of firmware for hardware a VM cannot have, 458 MB of
  documentation, and the .NET SDK only needed to *build* Pinta and OBS. The Rust
  and Go toolchains stay, so `yay` still works.

## Already downloaded the first one?

You do not need to fetch 3.6 GB. Run these inside the VM:

```bash
curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/18-avisos-que-no-se-apagan.sh | bash
curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
```

## What does not work in either

- **No GPU acceleration inside the VM.** Software rendering; blur and shadows
  are off. Fine for normal use, not for video or 3D.
- **Resolution is fixed at boot** (1920x1200, editable in
  `~/.config/hypr/monitors.lua`). Changing it at runtime whites out the screen.
- Single monitor.
- Proprietary apps are not bundled, on purpose. `omarchy-arm-extras` fetches
  1Password, Obsidian, Typora, LocalSend and Chrome from their official source.

---

Build script, documentation and the full write-up:
https://github.com/ggalancs/omarchy-arm-utm

Unofficial work, unaffiliated with Basecamp or the Omarchy project.
