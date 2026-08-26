#!/bin/bash
# 17 · The 37 defects found by the builder's audit
#
# This is not a script that runs: it is the record of what was fixed in
# build-omarchy-arm.sh and in provision/src/* after auditing it against its
# own sources of truth (the 16 fixes above and the findings from the
# article), with an independent refuter for each finding.
#
# BLOCKERS
#  1. sanitize.sh deleted /root/prov in step 7 and read it in steps 8a/8b:
#     the image ended up without the post-update hook or omarchy-arm-extras, in
#     silence. The deletion is now performed by repair.sh upon exiting the chroot.
#  2. stage3 runs as a user and /root is 0750: its guards [ -f /root/prov/... ]
#     returned false without error. stage2 leaves a copy in ~/.omarchy-arm-prov.
#  3. DIST_OLD_USER/DIST_NEW_USER were exported on the host and never crossed
#     to the guest: sanitization always renamed the literal "gabriel". Now
#     they travel in config.env and sanitize aborts if the user does not exist.
#  4. A total failure in stage3 degraded to a warning and the build was declared
#     correct. stage2 emits TOK_STAGE3_<rc> and ph_build checks it.
#  5. The distributable bundle's config.plist announced "User: gabriel /
#     gabriel": false and a leak. Parameterized and with verification in ph_package.
#  6. ph_utm deleted any UTM VM with the same name without asking.
#  7. make-utm.sh killed the entire UTM application, including the user's VMs.
#  8. ALPINE_ISO set to 3.24.1, which Alpine removes from the CDN upon publishing the
#     next patch. Now the last one is resolved and its sha256 is verified.
#  9. OMARCHY_REF=quattro without backup: if the branch disappears, prepare dies without
#     explaining why. Now it falls back to the default branch with a warning.
#
# MAJOR FINDINGS (selection)
#  · ph_verify collected metrics but did not compare them: it could not fail.
#  · ph_utm swallowed the make-utm.sh error with "| tail -4".
#  · ph_fetch announced "MD5 verified" even though the checksum curl failed.
#  · ph_package did not use -c: it did not reproduce the compressed image that was distributed.
#  · write_readme() generated a 17-line README with two false statements.
#    Now dist/LEEME.md is embedded as-is.
#  · The compilation loop had lost the -s from makepkg: without dependencies
#    compilation dependencies, most PKGBUILDs fail at the first step.
#  · Fix 15 (thinned) was not folded anywhere.
#  · ph_build destroyed the previous disk (40 min of work) without warning.
#
# MINOR FINDINGS (selection)
#  · The backup of $TERMINAL pointed to alacritty, which quattro does not install (foot).
#  · spice-vdagentd was never enabled: no shared clipboard.
#  · Four steps from fix 01 were missing: /etc/gnupg, systemd-oomd,
#    NetworkManager-wait-online and gnome-keyring PAM in SDDM.
#  · /root/STAGE2_OK and the random seed were included in the image.
#  · build.exp checked the dotfiles in /mnt/home/gabriel, fixed.
#
# AND FOUR ISSUES FOUND WHILE FIXING, which only appeared WHEN RUNNING
#  · confirm() used ${ans,,}, from bash 4: macOS ships with bash 3.2 and there the error occurs
#    expansion aborts the function, accidentally returning "yes". It appeared when
#    testing the questionnaire under a pty with expect; bash -n does not catch it.
#  · config.env was written without quotes and VM_FULLNAME="Omarchy ARM" caused
#    "ARM" to be executed as a command upon sourcing: chroot died with rc=127.
#  · The ph_verify heredoc was not quoted, so the host's bash
#    expanded the $(...) and the checks ran ON THE HOST
#    (pgrep with BSD syntax, systemctl nonexistent) instead of inside the VM.
#    Rewritten with <<'"'"'EXPEOF'"'"' and variables via $env(...) from Tcl.
#  · spice-vdagentd is a "static" unit: it is not enabled. One must enable
#    spice-vdagentd.socket. This was revealed by the freshly built VM.
#
# VALIDATION
#  Complete build from scratch (8/8 phases) on 2026-08-23 on an M3 Max:
#   · 17/17 tools compiled (only herdr fails, due to the Zig version)
#   · extras=yes menu=yes hook=yes  <- the three blocking ones, resolved
#   · verify inside the guest: H=1 Q=1 BINS=436 -> VEREDICTO_OK
#   · final image 4.1 GB; ~57 min without OBS/Pinta, ~1 h 50 with them
#  And the call that stage3 makes for OBS and Pinta, tested separately on that same
#  VM: rc=0, obs-studio 32.2.2-1, pinta 3.1.2-2, /usr/bin/obs ELF ARM aarch64.
echo "Registro documental. Los arreglos estan en build-omarchy-arm.sh y provision/src/."
