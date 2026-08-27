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
