#!/bin/bash
# 17 · Los 37 defectos que encontro la auditoria del builder
#
# No es un script que se ejecute: es el registro de lo que se corrigio en
# build-omarchy-arm.sh y en provision/src/* despues de auditarlo contra sus
# propias fuentes de verdad (los 16 fixes anteriores y los hallazgos del
# articulo), con un refutador independiente por hallazgo.
#
# BLOQUEANTES
#  1. sanitize.sh borraba /root/prov en el paso 7 y lo leia en los pasos 8a/8b:
#     la imagen salia sin el hook post-update ni omarchy-arm-extras, en
#     silencio. El borrado lo hace ahora repair.sh al salir del chroot.
#  2. stage3 corre como usuario y /root es 0750: sus guardas [ -f /root/prov/... ]
#     daban falso sin error. stage2 deja una copia en ~/.omarchy-arm-prov.
#  3. DIST_OLD_USER/DIST_NEW_USER se exportaban en el anfitrion y nunca cruzaban
#     al invitado: el sanitizado renombraba siempre el literal "gabriel". Ahora
#     viajan en config.env y sanitize aborta si el usuario no existe.
#  4. Un fallo total de stage3 se degradaba a warn y el build se declaraba
#     correcto. stage2 emite TOK_STAGE3_<rc> y ph_build lo comprueba.
#  5. El config.plist del bundle distribuible anunciaba "Usuario: gabriel /
#     gabriel": falso y una fuga. Parametrizado y con comprobacion en ph_package.
#  6. ph_utm borraba sin preguntar cualquier VM de UTM con el mismo nombre.
#  7. make-utm.sh mataba la aplicacion UTM entera, con las VMs del usuario dentro.
#  8. ALPINE_ISO fijado a 3.24.1, que Alpine retira del CDN al publicar el
#     siguiente parche. Ahora se resuelve el ultimo y se verifica su sha256.
#  9. OMARCHY_REF=quattro sin respaldo: si la rama desaparece, prepare muere sin
#     explicar por que. Ahora cae a la rama por defecto avisando.
#
# GRAVES (seleccion)
#  · ph_verify recogia metricas y no las comparaba: no podia fallar.
#  · ph_utm se tragaba el error de make-utm.sh con "| tail -4".
#  · ph_fetch anunciaba "MD5 verificado" aunque el curl del checksum fallara.
#  · ph_package no usaba -c: no reproducia la imagen comprimida que se distribuyo.
#  · write_readme() generaba un LEEME de 17 lineas con dos afirmaciones falsas.
#    Ahora se embebe dist/LEEME.md tal cual.
#  · El bucle de compilacion habia perdido el -s de makepkg: sin dependencias
#    de compilacion, la mayoria de los PKGBUILD fallan en el primer paso.
#  · El fix 15 (adelgazado) no estaba plegado en ninguna parte.
#  · ph_build destruia el disco anterior (40 min de trabajo) sin avisar.
#
# MENORES (seleccion)
#  · El respaldo de $TERMINAL apuntaba a alacritty, que quattro no instala (foot).
#  · spice-vdagentd nunca se habilitaba: sin portapapeles compartido.
#  · Faltaban cuatro pasos del fix 01: /etc/gnupg, systemd-oomd,
#    NetworkManager-wait-online y el PAM de gnome-keyring en SDDM.
#  · /root/STAGE2_OK y la semilla de aleatoriedad viajaban en la imagen.
#  · build.exp comprobaba los dotfiles en /mnt/home/gabriel, fijo.
#
# Y CUATRO COMETIDOS AL ARREGLAR, que solo aparecieron EJECUTANDO
#  · confirm() usaba ${ans,,}, de bash 4: macOS trae bash 3.2 y ahi el error de
#    expansion aborta la funcion, devolviendo "si" por accidente. Aparecio al
#    probar el cuestionario bajo un pty con expect; bash -n no lo ve.
#  · config.env se escribia sin comillas y VM_FULLNAME="Omarchy ARM" hacia que
#    "ARM" se ejecutara como comando al hacer source: chroot muerto con rc=127.
#  · El heredoc de ph_verify no iba entrecomillado, asi que el bash del
#    anfitrion expandia los $(...) y las comprobaciones se ejecutaban EN EL MAC
#    (pgrep con sintaxis BSD, systemctl inexistente) en vez de dentro de la VM.
#    Reescrito con <<'"'"'EXPEOF'"'"' y las variables por $env(...) de Tcl.
#  · spice-vdagentd es una unidad "static": no se habilita. Hay que habilitar
#    spice-vdagentd.socket. Lo revelo la VM recien construida.
#
# VALIDACION
#  Construccion completa de cero (8/8 fases) el 2026-08-23 sobre un M3 Max:
#   · 17/17 herramientas compiladas (solo falla herdr, por la version de Zig)
#   · extras=si menu=si hook=si  <- los tres bloqueantes, resueltos
#   · verify dentro del invitado: H=1 Q=1 BINS=436 -> VEREDICTO_OK
#   · imagen final 4,1 GB; ~57 min sin OBS/Pinta, ~1 h 50 con ellos
#  Y la llamada que stage3 hace para OBS y Pinta, probada aparte en esa misma
#  VM: rc=0, obs-studio 32.2.2-1, pinta 3.1.2-2, /usr/bin/obs ELF ARM aarch64.
echo "Registro documental. Los arreglos estan en build-omarchy-arm.sh y provision/src/."
