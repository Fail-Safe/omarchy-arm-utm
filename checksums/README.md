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
installed during the privileged provisioning path. Builds fetch column 4 only;
they never fall back to the branch or `HEAD` in column 3.

Run `scripts/update-core-source-pins.sh --verify` to resolve current upstream
refs, verify that every recorded commit remains directly fetchable, and print a
reviewable diff. After reviewing the source changes, pass `--write` to update
the manifest and re-embed it in the standalone builder.

This locks source selection, not all binary inputs: Arch Linux ARM repositories
and language package registries remain live dependency sources.

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
