#!/usr/bin/env python3
"""Re-embed provision/src/* in build-omarchy-arm.sh __PAYLOAD_*__ heredocs."""
import os, re, subprocess, sys

LANGUAGE = os.environ.get("OMARCHY_LANG", "auto")
if LANGUAGE == "auto":
    try:
        locale = subprocess.run(
            ["defaults", "read", "-g", "AppleLocale"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
        keyboard = subprocess.run(
            ["defaults", "read", os.path.expanduser("~/Library/Preferences/com.apple.HIToolbox.plist"),
             "AppleSelectedInputSources"],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        locale = keyboard = ""
    LANGUAGE = "es" if (re.search(r"(?:_|-)(?:ES|MX)(?:@|_|-|$)|@rg=(?:ES|MX)", locale)
                         or re.search(r"Spanish|Mexican|Mexico", keyboard, re.I)) else "en"
elif LANGUAGE not in {"en", "es"}:
    raise SystemExit(f"Invalid OMARCHY_LANG={LANGUAGE!r}; expected auto, en, or es")

def ui_text(english, spanish):
    return spanish if LANGUAGE == "es" else english

RAIZ=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECK=sys.argv[1:] == ["--check"]
if sys.argv[1:] not in ([], ["--check"]):
    raise SystemExit("usage: scripts/sync-payloads.py [--check]")
MAPA={
 "__PAYLOAD_CORE_GIT_SOURCES_TSV__":"checksums/core-git-sources.tsv",
 "__PAYLOAD_PROVISION_STAGE1_SH__":"provision/src/stage1.sh",
 "__PAYLOAD_PROVISION_STAGE2_SH__":"provision/src/stage2.sh",
 "__PAYLOAD_PROVISION_STAGE3_SH__":"provision/src/stage3.sh",
 "__PAYLOAD_PROVISION_REPAIR_SH__":"provision/src/repair.sh",
 "__PAYLOAD_PROVISION_SANITIZE_SH__":"provision/src/sanitize.sh",
 "__PAYLOAD_PROVISION_EXTRAS_SH__":"provision/src/omarchy-arm-extras",
 "__PAYLOAD_PROVISION_CLIPBRD_SH__":"provision/src/omarchy-arm-clipboard",
 "__PAYLOAD_PROVISION_VDAGENT_PY__":"provision/src/omarchy-arm-vdagent",
 "__PAYLOAD_PROVISION_SHARE_SH__":"provision/src/omarchy-arm-share",
 "__PAYLOAD_LEEME_MD__":"provision/src/LEEME.md",
 "__PAYLOAD_PROVISION_ARMSYNC_SH__":"provision/src/hooks/10-arm-sync",
 "__PAYLOAD_SCRIPTS_BUILD_EXP__":"scripts/build.exp",
 "__PAYLOAD_SCRIPTS_REPAIR_EXP__":"scripts/repair.exp",
 "__PAYLOAD_SCRIPTS_MAKE-UTM_SH__":"scripts/make-utm.sh",

}
p=os.path.join(RAIZ,"build-omarchy-arm.sh")
lineas=open(p).read().split("\n")
cambios=0
for marca,rel in MAPA.items():
    ini=next((i for i,l in enumerate(lineas) if l.rstrip().endswith("<<'%s'"%marca)), None)
    if ini is None: print(ui_text(f"  !! missing opening marker: {marca}", f"  !! sin apertura: {marca}")); continue
    fin=next(j for j in range(ini+1,len(lineas)) if lineas[j]==marca)
    nuevo=open(os.path.join(RAIZ,rel)).read().rstrip("\n").split("\n")
    if lineas[ini+1:fin]==nuevo: continue
    lineas[ini+1:fin]=nuevo
    cambios+=1
    print(ui_text(f"  re-embedded {os.path.basename(rel)} ({len(nuevo)} lines)",
                  f"  re-incrustado {os.path.basename(rel)} ({len(nuevo)} lineas)"))
if cambios and CHECK:
    raise SystemExit(ui_text(f"{cambios} payload(s) are out of sync",
                             f"{cambios} payload(s) desincronizados"))
if not CHECK:
    open(p,"w").write("\n".join(lineas))
print(ui_text(f"  {cambios} payload(s) updated" if cambios else "  all payloads are already synchronized",
              f"  {cambios} payload(s) actualizados" if cambios else "  todo ya estaba sincronizado"))

# A payload without a MAPA entry is a file that no one will ever sync again:
# you edit the source, nothing happens, and the build continues deploying the old version.
todas=set(re.findall(r"<<'(__PAYLOAD_[A-Z0-9_.-]+__)'", "\n".join(lineas)))
huerfanas=sorted(todas - set(MAPA))
if huerfanas:
    print(ui_text("  no declared source (the payload itself is the source of truth):",
                  "  sin fuente declarada (su fuente de verdad es el propio payload):"))
    for h in huerfanas: print(f"    {h}")
