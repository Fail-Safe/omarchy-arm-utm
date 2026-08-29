# Pinned base images

The normal build accepts only the base-image bytes recorded in
`base-images.sha256`. The same values are embedded in `build-omarchy-arm.sh` so
the builder remains usable as a single standalone file.

The pins recorded on 2026-08-26 were established as follows:

- `alpine-virt-3.24.1-aarch64.iso`: SHA-256 published beside the ISO on
  Alpine's HTTPS CDN.
- `ArchLinuxARM-aarch64-latest.tar.gz`: byte-identical downloads from the
  official California and Florida HTTPS mirrors, plus a valid detached
  signature from Arch Linux ARM Build System fingerprint
  `68B3537F39A313B3E574D06777193F152BDBE6A6`.
- The signing key was taken from `archlinuxarm/archlinuxarm-keyring` commit
  `91e6b11698f8df66042d56aaa56fbe9c9263847d`; the pinned `builder.asc` SHA-256
  is `26196ae6d6efbb1138be6805245d577adbcd94b887eaf0569f88efe003e6b3d9`.

Run `scripts/update-base-image-pins.sh` to verify current upstream artifacts and
print proposed pins. Pass `--write` only after reviewing the verification
output; it updates the manifest and the standalone builder together.

# Core Git sources

`core-git-sources.tsv` pins every Git repository whose contents are built or
installed during privileged provisioning or by the optional-app installer.
Builds and installers fetch column 4 only; they never fall back to the branch or
`HEAD` in column 3.

Run `scripts/update-core-source-pins.sh --verify` to resolve current upstream
refs, verify that every recorded commit remains directly fetchable, and print a
reviewable diff. After reviewing the source changes, pass `--write` to update
the manifest and re-embed it in the standalone builder.

This locks source selection, not all binary inputs. Language package registries
remain live dependency sources. Arch Linux ARM repositories are handled by the
per-build snapshot described below rather than by a long-lived checked-in pin.

`PINNED` in the refresh-ref column means the commit is derived from another
reviewed source rather than independently following a remote branch. The OBS
submodule commits use this form because they must match the gitlinks in the
reviewed OBS source commit.

# Default free-app artifacts

`free-app-artifacts.tsv` records the exact Pinta package URL, SHA-256, and Arch
package-signing fingerprint used by the default `INCLUDE_LIBRE_APPS=yes` build. The
installer downloads both the package and its detached signature, verifies the
reviewed digest and signer, and only then permits `pacman -U`. Stage 2 populates
the Arch Linux keyring bundled in the reviewed base image alongside the Arch
Linux ARM keyring.

When updating Pinta, review the package metadata and its `dotnet-runtime-*`
dependency together with the pinned `dotnet-core-bin` recipe. Record the new
exact URL, digest, and signer fingerprint, re-embed the payload, and run the
full default VM build; selecting the newest mirror filename at build time is
intentionally unsupported.

# Optional proprietary-app inputs

`optional-app-artifacts.tsv` records exact reviewed downloads for the
user-invoked 1Password, Obsidian, and Zed installers. 1Password must match both the
recorded SHA-256 and its mandatory detached signature from fingerprint
`3FEF9748469ADBE15DA7CA80AC2D62742012EA22`; the signing key is downloaded from
1Password's HTTPS key endpoint into an isolated temporary keyring and its full
fingerprint is checked. Obsidian and Zed publish no detached signature, so their
exact versioned GitHub release URLs and SHA-256 values are the trust boundary.

The 1Password CLI, Typora, LocalSend, Google Chrome, and Zed's Omazed theme helper use exact AUR
recipe commits from `core-git-sources.tsv`; those reviewed recipes in turn pin
their official aarch64 artifacts with makepkg checksums or signatures. Refresh
these security-sensitive pins promptly when reviewing a vendor update. Until
then, `--force` reinstalls the reviewed version instead of discovering the
newest release at runtime.

# Per-build Arch Linux ARM repository snapshot

The `prepare` phase captures `core`, `extra`, `alarm`, and `aur` as one set. It
requires a stable `/aarch64/sync` marker and byte-identical databases from the
configured California and Florida official HTTPS mirrors. The resulting
`alarm-repositories/manifest.tsv` records the sources, capture time, sync marker,
size, SHA-256, and a snapshot ID for all four databases.

Arch Linux ARM signs packages but does not sign repository databases. The build
therefore authenticates database selection through agreement between the two
official HTTPS mirrors, then relies on pacman's required package signatures for
the selected package bytes. Stage 2 verifies and installs the captured databases
before any transaction and never refreshes them during provisioning.

The installed image retains the snapshot manifest and databases under
`/usr/share/omarchy-arm/alarm-repositories/`, plus
`alarm-package-provenance.tsv`. Its evidence field distinguishes packages
proved against cached package bytes and the installed mtree from metadata-only,
ambiguous, local, and unknown records. Exact snapshot candidates retain their
versions, package hashes, and database-recorded PGP-signature hashes without
claiming that metadata coincidence proves origin. This is not an offline
archive: if a mirror removes a selected package before it is downloaded, the
build fails closed. After installation, the normal live HTTPS mirrorlist remains
configured, so a later user-initiated `pacman -Syu` works normally.
