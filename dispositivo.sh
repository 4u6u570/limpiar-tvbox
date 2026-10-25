#!/system/bin/sh
# Corre DENTRO del TV box, como root. Lo lanza limpiar-tvbox.sh en segundo plano (nohup) para
# que un corte del ADB por Wi-Fi no lo interrumpa: el avance queda en informe.txt y, al
# terminar, aparece el archivo `listo`.
#
# Uso: dispositivo.sh <analizar|limpiar> <quitar_apps 0|1> <optimizar 0|1> <cerrar_adb 0|1>
#
# Todo lo que se modifica se copia antes a cuarentena/, que limpiar-tvbox.sh se trae a la
# computadora. Nada se borra de la partición del sistema salvo las APK de preinstalación.

MODO=${1:-analizar}
QUITAR_APPS=${2:-0}
OPTIMIZAR=${3:-0}
CERRAR_ADB=${4:-0}

BASE=/data/local/tmp/limpiar-tvbox
IOC=$BASE/indicadores.txt
INFORME=$BASE/informe.txt
CUAR=$BASE/cuarentena
LISTO=$BASE/listo

umask 022
mkdir -p $CUAR
: > $INFORME
rm -f $LISTO

log() { echo "$*" >> $INFORME; }
titulo() { log ""; log "== $* =="; }
limpiando() { [ "$MODO" = limpiar ]; }

# Valores de un tipo del archivo de indicadores, sin comentarios ni espacios.
ioc() {
  grep -E "^$1[[:space:]]" $IOC | sed -E 's/#.*//; s/^[^[:space:]]+[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
}

# Dominios conocidos más URLs con dominios de bajo costo, típicos de servidores de control.
DOMINIOS=$(ioc dominio | sed 's/\./\\./g' | tr '\n' '|')
PATRON="${DOMINIOS}https?://[a-z0-9.-]+\.(online|pw|xyz|top|vip|icu|club|shop)/"

escribible() { mount -o rw,remount / 2>/dev/null || mount -o rw,remount /system 2>/dev/null; }
solo_lectura() { sync; mount -o ro,remount / 2>/dev/null || mount -o ro,remount /system 2>/dev/null; }

# Copia un archivo a la cuarentena con su ruta completa en el nombre.
resguardar() { cp -p "$1" "$CUAR/$(echo "$1" | sed 's#^/##; s#/#__#g')" 2>/dev/null; }

RCS=$(ls /init*.rc /system/etc/init/*.rc /vendor/etc/init/*.rc /vendor/etc/init/hw/*.rc \
         /product/etc/init/*.rc /odm/etc/init/*.rc 2>/dev/null)

log "limpiar-tvbox: modo $MODO ($(date '+%Y-%m-%d %H:%M'))"

# ---------------------------------------------------------------------------------------------
titulo "Equipo"
SDK=$(getprop ro.build.version.sdk)
case $SDK in
  28) REAL=9 ;; 29) REAL=10 ;; 30) REAL=11 ;; 31|32) REAL=12 ;; 33) REAL=13 ;; 34) REAL=14 ;;
  35) REAL=15 ;; *) REAL="?" ;;
esac
DECLARADO=$(getprop ro.build.version.release)
log "Modelo:  $(getprop ro.product.manufacturer) $(getprop ro.product.model)"
log "Android: dice $DECLARADO; en realidad es Android $REAL (API $SDK)"
[ "${DECLARADO%%.*}" != "$REAL" ] && log "  ! La versión que muestra es falsa."

RAM_MB=$(( $(grep MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2) / 1024 ))
PLACA=$(tr -d '\0' < /proc/device-tree/amlogic-dt-id 2>/dev/null)
log "RAM:     reporta $RAM_MB MB"
if [ -n "$PLACA" ]; then
  log "Placa:   $PLACA"
  case $PLACA in
    *_1g*) [ $RAM_MB -gt 1500 ] && log "  ! La placa es de 1 GB: la RAM que reporta es falsa." ;;
    *_2g*) [ $RAM_MB -gt 2600 ] && log "  ! La placa es de 2 GB: la RAM que reporta es falsa." ;;
  esac
fi
log "Build:   $(getprop ro.build.type) / $(getprop ro.build.tags); SELinux $(getenforce)"
[ "$(getprop ro.build.type)" = userdebug ] && log "  ! Compilación de prueba (userdebug): sin las protecciones de un equipo de venta."
[ "$(getenforce)" != Enforcing ] && log "  ! SELinux no está aplicando sus reglas."

# ---------------------------------------------------------------------------------------------
titulo "Servicios de arranque"
for rc in $RCS; do
  sed -nE "s#^service[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+).*#$rc \1 \2#p" "$rc"
done > $BASE/servicios.tmp

HALLADOS=0
CONOCIDOS=$(ioc servicio)
while read -r rc nombre ruta; do
  binario=$(basename "$ruta")
  motivo=""
  for c in $CONOCIDOS; do
    [ "$nombre" = "$c" ] || [ "$binario" = "$c" ] && motivo="malware conocido"
  done
  if [ -z "$motivo" ] && [ -f "$ruta" ] && strings "$ruta" 2>/dev/null | grep -qiE "$PATRON"; then
    motivo="contiene direcciones de servidores sospechosos"
  fi
  [ -z "$motivo" ] && continue
  HALLADOS=$((HALLADOS + 1))

  if [ ! -f "$ruta" ]; then
    log "  - $nombre ($ruta): ya estaba neutralizado"
    continue
  fi
  log "  ! $nombre ($ruta): $motivo"

  # Frenarlo siempre, aun analizando: hasta el próximo reinicio y sin tocar archivos. Es lo que
  # evita que cierre el ADB a mitad del trabajo.
  setprop ctl.stop "$nombre"
  for p in $(pidof "$binario"); do kill -9 "$p"; done

  if limpiando; then
    resguardar "$ruta"
    resguardar "$rc"
    escribible
    # Sin binario, init no puede arrancarlo; se comentan además los `start` para no dejar errores.
    sed -i -E "s/^([[:space:]]*start[[:space:]]+$nombre)[[:space:]]*\$/#\1/" "$rc"
    mv "$ruta" "$ruta.disabled" && chmod 000 "$ruta.disabled"
    solo_lectura
    log "    neutralizado: $ruta.disabled, sin permiso de ejecución"
  else
    log "    frenado hasta el próximo reinicio"
  fi
done < $BASE/servicios.tmp
rm -f $BASE/servicios.tmp
[ $HALLADOS = 0 ] && log "  Nada sospechoso."

# ---------------------------------------------------------------------------------------------
titulo "Proxyware en /data/adb"
if [ -d /data/adb ]; then
  for p in /proc/[0-9]*; do
    case "$(readlink $p/exe 2>/dev/null)" in
      /data/adb/*) log "  ! Corriendo: $(readlink $p/exe) (pid ${p#/proc/})"
                   limpiando && kill -9 "${p#/proc/}" ;;
    esac
  done

  # El lanzador monta /proc, /sys y /dev dentro de cada SDK: hay que desmontarlos antes de
  # borrar, o el borrado alcanzaría los dispositivos del sistema.
  if limpiando; then
    grep ' /data/adb/' /proc/mounts | cut -d' ' -f2 | sort -r | while read -r m; do
      umount -f "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
    done
  fi

  ADB_IOC=$(ioc adb)
  VISTOS=0
  for e in /data/adb/* /data/adb/.[!.]*; do
    [ -e "$e" ] || continue
    VISTOS=1
    n=$(basename "$e")
    raiz=${n%.tar}
    raiz=${raiz%.lock}
    malo=0
    for i in $ADB_IOC; do [ "$raiz" = "$i" ] && malo=1; done
    tam=$(du -sh "$e" 2>/dev/null | cut -f1)

    if [ $malo = 0 ]; then
      log "  ? $n ($tam): no figura en los indicadores, no se toca (Magisk, por ejemplo, vive acá)"
      continue
    fi
    log "  ! $n ($tam)"
    limpiando || continue
    if grep -q " $e" /proc/mounts; then
      log "    sigue montado algo adentro: no se borra"
      continue
    fi
    # -xdev: nunca cruzar a otro sistema de archivos, por si quedó un montaje.
    find "$e" -xdev -depth -delete 2>/dev/null
    [ -e "$e" ] && log "    no se pudo borrar del todo" || log "    borrado"
  done
  [ $VISTOS = 0 ] && log "  Vacío."
else
  log "  No existe."
fi

# ---------------------------------------------------------------------------------------------
titulo "Apps de sistema sospechosas"
DESACTIVADAS=$(pm list packages -d | sed 's/package://')
HAY=0
for p in $(ioc paquete); do
  pm list packages | grep -qx "package:$p" || continue
  HAY=1
  if echo "$DESACTIVADAS" | grep -qx "$p"; then
    log "  - $p: ya desactivada"
    continue
  fi
  log "  ! $p ($(pm path $p | head -1 | sed 's/package://'))"
  if limpiando; then
    am force-stop "$p"
    pm disable "$p" >/dev/null && log "    desactivada (se revierte con: pm enable $p)"
  fi
done
[ $HAY = 0 ] && log "  Ninguna de las conocidas."

log ""
log "  Servicios de accesibilidad instalados (pueden leer y tocar la pantalla):"
pm query-services --brief -a android.accessibilityservice.AccessibilityService 2>/dev/null \
  | grep / | sed 's/^/    /' >> $INFORME

# ---------------------------------------------------------------------------------------------
titulo "APK de preinstalación"
# preinstall.sh las instala después de cada reset de fábrica: un reset devuelve las apps piratas.
HAY=0
for d in /system/preinstall /vendor/preinstall /product/preinstall /system/etc/preinstall; do
  ls $d/*.apk >/dev/null 2>&1 || continue
  HAY=1
  log "  $d:"
  for a in $d/*.apk; do log "    $(basename "$a")"; done
  if limpiando; then
    escribible
    rm -f $d/*.apk
    solo_lectura
    log "    borradas: un reset de fábrica ya no las reinstala"
  fi
done
[ $HAY = 0 ] && log "  No hay."

# ---------------------------------------------------------------------------------------------
titulo "Verificación de conexión a internet"
URL=$(settings get global captive_portal_https_url)
case "$URL" in
  null|*google.com*|*gstatic.com*) log "  La estándar de Google." ;;
  *)
    log "  ! Consulta a $URL en cada conexión"
    if limpiando; then
      settings put global captive_portal_https_url https://connectivitycheck.gstatic.com/generate_204
      settings put global captive_portal_http_url http://connectivitycheck.gstatic.com/generate_204
      log "    vuelta a la de Google"
    fi ;;
esac

# ---------------------------------------------------------------------------------------------
titulo "MAC del Wi-Fi"
MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null)
LEE_ARCHIVO=0
for m in $(cut -d' ' -f1 /proc/modules); do
  for ko in /vendor/lib/modules/$m.ko /system/lib/modules/$m.ko; do
    [ -f "$ko" ] && strings "$ko" | grep -q '/data/wifimac.txt' && LEE_ARCHIVO=1
  done
done
if [ $LEE_ARCHIVO = 0 ]; then
  log "  Actual: $MAC. El driver no lee una MAC de archivo; no se puede fijar desde acá."
elif [ -f /data/wifimac.txt ]; then
  log "  Fija en /data/wifimac.txt: $(cat /data/wifimac.txt)"
else
  log "  ! Cambia en cada arranque (y con ella la IP). Actual: $MAC"
  if limpiando; then
    echo "$MAC" > /data/wifimac.txt
    chmod 644 /data/wifimac.txt
    log "    fijada en /data/wifimac.txt"
  fi
fi

# ---------------------------------------------------------------------------------------------
titulo "Otros programas con direcciones sospechosas"
HAY=0
for f in /system/bin/* /system/xbin/* /vendor/bin/* /vendor/xbin/*; do
  [ -f "$f" ] || continue
  case "$f" in *.disabled) continue ;; esac
  if strings "$f" 2>/dev/null | grep -qiE "$PATRON"; then
    HAY=1
    log "  ? $f: $(strings "$f" | grep -oiE "$PATRON[a-z0-9/_.-]*" | sort -u | head -3 | tr '\n' ' ')"
  fi
done
[ $HAY = 0 ] && log "  Ninguno."

# ---------------------------------------------------------------------------------------------
titulo "Apps instaladas"
pm list packages -3 | sed 's/package://' | sort > $BASE/apps.tmp
if [ -s $BASE/apps.tmp ]; then
  while read -r p; do
    if [ "$QUITAR_APPS" = 1 ] && limpiando; then
      pm uninstall "$p" >/dev/null 2>&1 && log "  - $p: desinstalada" || log "  ! $p: no se pudo desinstalar"
    else
      log "  $p"
    fi
  done < $BASE/apps.tmp
else
  log "  Ninguna."
fi
rm -f $BASE/apps.tmp

# ---------------------------------------------------------------------------------------------
if [ "$OPTIMIZAR" = 1 ] && limpiando; then
  titulo "Optimización"
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    settings put global $k 0.5
  done
  log "  Animaciones a 0,5x."
  if ! settings get secure enabled_accessibility_services | grep -q talkback; then
    pm disable com.google.android.marvin.talkback >/dev/null 2>&1 && log "  TalkBack desactivado (no estaba en uso)."
  fi
fi

# ---------------------------------------------------------------------------------------------
if [ "$CERRAR_ADB" = 1 ] && limpiando; then
  titulo "ADB por red"
  for rc in $RCS; do
    grep -q 'service.adb.tcp.port' "$rc" || continue
    resguardar "$rc"
    escribible
    sed -i -E 's/^([[:space:]]*setprop[[:space:]]+service\.adb\.tcp\.port.*)$/#\1/' "$rc"
    solo_lectura
    log "  Comentado en $rc: desde el próximo arranque el ADB por red no se abre solo."
  done
fi

# ---------------------------------------------------------------------------------------------
titulo "Root"
if [ -e /system/xbin/su ] || [ -e /system/bin/su ]; then
  log "  ! Hay su de fábrica: cualquier app que lo pida puede obtener root. No se toca;"
  log "    sacarlo es decisión de cada uno (en equipos userdebug, \`adb root\` sigue funcionando)."
else
  log "  Sin su."
fi

titulo "Conexiones abiertas en este momento"
netstat -tnp 2>/dev/null | grep ESTABLISHED | grep -v ':5555 ' | sed 's/^/  /' >> $INFORME

log ""
log "Fin."
chmod -R a+rX $BASE
touch $LISTO
