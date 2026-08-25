# Which file should I download?

**`omarchy-arm-utm.zip`** — there is only one, and it is the current one.

| | |
|---|---|
| Size | 3.6 GB (7.2 GB unpacked) |
| Published | 2026-08-25 |
| `sha256` | `b547e9e5d1d0fdf1c7b642ecf5b8274064f6eb99485acef6b273e596bc47ec3a` |

Arch Linux ARM aarch64 · Hyprland 0.56.1 · the Omarchy 4 desktop · 440
`omarchy-*` commands · 17 tools built for ARM · OBS Studio and Pinta.

```bash
shasum -a 256 -c omarchy-arm-utm.zip.sha256
unzip omarchy-arm-utm.zip
open "Omarchy ARM.utm"
```

User `omarchy`, password `omarchy` (also root). **Change it with `passwd`.**

## What works out of the box

Verified by booting this exact image before publishing it:

- **Shared clipboard, both ways** — copy on the Mac, paste in the VM, and back.
  Text only. Needs "Share clipboard" enabled in UTM, and the VM **open as a
  window**: started headless via `utmctl` there is no SPICE client attached, so
  the channel exists but carries nothing.
- **Shared folder** — pick one in *VM Settings → Sharing*, then run
  `omarchy-arm-share` in the guest. It handles both VirtFS and SPICE WebDAV.
- `omarchy-update`, snapper snapshots, and the 439 `omarchy-*` commands.

## What does not

- **No GPU acceleration inside the VM.** Software rendering; blur and shadows
  are off. Fine for normal use, not for video or 3D.
- **Resolution is fixed at boot** (1920x1200, editable in
  `~/.config/hypr/monitors.lua`). Changing it at runtime whites out the screen.
- **`herdr` is missing** — it wants Zig 0.15 semantics and the repos are on
  0.16, on ARM and x86_64 alike.
- Single monitor.
- Proprietary apps are not bundled, on purpose. `omarchy-arm-extras` fetches
  1Password, Obsidian, Typora, LocalSend and Chrome from their official source.

## Earlier uploads, and why they are gone

Two previous versions were published and have been removed, rather than left
alongside this one as half-working variants:

| | | |
|---|---|---|
| 2026-08-23 | 6.5 GB | Worked, but two notifications never went away, and the clipboard did not work at all |
| 2026-08-24 | 3.6 GB | Fixed the notifications, dropped 45% of the size. Clipboard still broken |
| 2026-08-25 | 3.6 GB | **This one.** Clipboard and shared folder verified working on a booted image |

**Already downloaded an earlier one?** You do not need to fetch 3.6 GB again.
Run these inside the VM:

```bash
curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/18-avisos-que-no-se-apagan.sh | bash
curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
```

Note on checksums: if you kept the `sha256` of an earlier download, it will no
longer match anything published here. The file name is the same; the contents
are newer.

---

Build script, documentation and the full write-up:
https://github.com/ggalancs/omarchy-arm-utm

Unofficial work, unaffiliated with Basecamp or the Omarchy project.
