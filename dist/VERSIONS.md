# Which file should I download?

**`omarchy-arm-utm-v2.zip`** — smaller, and everything works.

| | `omarchy-arm-utm-v2.zip` | `omarchy-arm-utm.zip` |
|---|---|---|
| | **← download this one** | the first release |
| Size | 3.6 GB (7.2 GB unpacked) | 6.5 GB (13 GB unpacked) |
| Published | 2026-08-25 | 2026-08-23 |
| Shared clipboard | **works** | does not work |
| "Update System" notification | gone | repeats on every boot |
| "Reboot?" after each update | gone | repeats forever |
| `sha256` | `b547e9e5d1d0fdf1c7b642ecf5b8274064f6eb99485acef6b273e596bc47ec3a` | `9d6afb16843bd868c9503dbfdaaa5f1ff7634b23f9a972b344ec27ca0a795fb4` |

The plain name belongs to the first release and keeps it, so links and checksums
published back in August still resolve to the exact bytes they were written
for. That is the only reason the better file is the one with `-v2` in its name.

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

User `omarchy`, password `omarchy` (also root). **Change it with `passwd`.**

Arch Linux ARM aarch64 · Hyprland 0.56.1 · the Omarchy 4 desktop · 439
`omarchy-*` commands · 17 tools built for ARM · OBS Studio and Pinta.

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
- **`herdr` is missing** — it wants Zig 0.15 semantics and the repos are on
  0.16, on ARM and x86_64 alike.
- Single monitor.
- Proprietary apps are not bundled, on purpose. `omarchy-arm-extras` fetches
  1Password, Obsidian, Typora, LocalSend and Chrome from their official source.

---

Build script, documentation and the full write-up:
https://github.com/ggalancs/omarchy-arm-utm

Unofficial work, unaffiliated with Basecamp or the Omarchy project.
