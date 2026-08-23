#!/bin/bash
# 18 · Los dos avisos que no se apagan nunca
#
# Ejecutar DENTRO de la VM:   bash 18-avisos-que-no-se-apagan.sh
#
# SÍNTOMA A — "Update System" reaparece en cada arranque aunque todo esté al día.
#   omarchy-provision-first-run solo marca first-run como hecho si NINGÚN paso
#   falla. Aquí fallaba siempre enable-user-units.sh, porque cinco ficheros
#   .service apuntan a /usr/bin/omarchy-* y esta imagen tenía los comandos en
#   /usr/local/bin. Al no marcarse, first-run se repite en cada login y
#   install/user/first-run/wifi.sh vuelve a lanzar el aviso.
#
# SÍNTOMA B — "Linux kernel has been updated. Reboot?" sale siempre.
#   omarchy-update-restart busca un vmlinuz dentro de /usr/lib/modules/<ver>/
#   que pertenezca a un paquete. En Arch x86_64 lo instala el paquete linux; en
#   Arch Linux ARM, linux-aarch64 deja la imagen en /boot/Image y no crea ese
#   vmlinuz. El bucle no encuentra nada, kernel_updated se queda en true y pide
#   reiniciar en cada actualización. Reiniciar no ayuda: la condición no puede
#   volverse falsa.
set -uo pipefail
echo "==> A. comandos de omarchy a /usr/bin (donde los espera el árbol)"
n=0
for f in /usr/share/omarchy/bin/*; do
  [ -f "$f" ] || continue
  sudo ln -sfn "$f" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "   $n comandos enlazados en /usr/bin"

echo "==> B. envoltorio para el aviso de kernel"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep lo genera depmod y no pertenece a ningun paquete. modules.builtin
  # si lo trae linux-aarch64, asi que sirve para saber si el directorio de
  # modulos del kernel en ejecucion es el del paquete instalado.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  [ -n "$pkg" ] && export OMARCHY_KERNEL_CURRENT=1
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "   /usr/local/bin/omarchy-update-restart"

echo "==> C. completar first-run para que deje de repetirse"
bash /usr/share/omarchy/install/user/first-run/enable-user-units.sh \
  && echo "   enable-user-units.sh: ahora sí" \
  || echo "   sigue fallando: mira 'systemctl --user status' de las seis unidades"
omarchy-provision-first-run --force 2>&1 | tail -3

echo "==> comprobación"
printf "   first-run marcado:  %s\n" "$(omarchy-done check first-run-user && echo sí || echo NO)"
printf "   kernel en ejecución: %s\n" "$(uname -r)"
printf "   lo posee:            %s\n" "$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null || echo "(nadie)")"
echo "   omarchy-update-restart no debería pedir reinicio a partir de ahora."
