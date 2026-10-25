#!/usr/bin/env bash
# limpiar-tvbox: analiza y limpia TV box Android genéricos que traen malware de fábrica.
#
# Corre en la computadora (macOS o Linux) y maneja el equipo por ADB. El trabajo pesado lo hace
# dispositivo.sh dentro del equipo y en segundo plano, porque el ADB por Wi-Fi de estos equipos
# se corta seguido. Ver README.md.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
REMOTO=/data/local/tmp/limpiar-tvbox
PUERTO=5555

MODO=analizar
IP=""
ESPERAR=0
QUITAR_APPS=0
OPTIMIZAR=0
CERRAR_ADB=0
REINICIAR=1
LAUNCHER=1
APPS=1
ZONA=""

ayuda() {
  cat <<'EOF'
Uso: ./limpiar-tvbox.sh [opciones]

Sin opciones, busca el equipo en la red y lo ANALIZA: no cambia nada.

  --limpiar         Neutraliza el malware y lo demás que encuentre. Antes copia cada archivo
                    que toca a informes/<equipo>/cuarentena.
  --ip IP           IP del equipo. Sin esto, lo busca solo en la red.
  --esperar         Espera a que el equipo abra el ADB (usalo justo después de prenderlo).
  --quitar-apps     Con --limpiar: desinstala TODAS las apps no del sistema (las piratas
                    incluidas). Las que quieras, después las instalás desde Play Store.
  --optimizar       Con --limpiar: animaciones más rápidas y TalkBack apagado si no se usa.
  --cerrar-adb      Con --limpiar: al terminar, cierra el ADB por red (recomendado si no vas a
                    volver a entrar; abierto, cualquiera en tu red puede tener root).
  --sin-apps        Con --limpiar: no instala las apps de base (WebView al día, TV Bro, Spotify y
                    TuneIn).
  --sin-launcher    Con --limpiar: no instala Vidrio Launcher (por defecto se instala y queda
                    como pantalla de inicio).
  --zona ZONA       Con --limpiar: fija la zona horaria (por ejemplo America/Argentina/Salta).
                    Muchos vienen con la de Londres o la de China y muestran mal la hora.
  --sin-reinicio    No reinicia al final para verificar.
  -h, --ayuda       Esta ayuda.

Ejemplos:
  ./limpiar-tvbox.sh                                # solo mirar
  ./limpiar-tvbox.sh --limpiar --esperar            # limpiar; prender el equipo después
  ./limpiar-tvbox.sh --limpiar --quitar-apps --optimizar --cerrar-adb --ip 192.168.0.50
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --limpiar) MODO=limpiar ;;
    --ip) IP=${2:-}; shift ;;
    --esperar) ESPERAR=1 ;;
    --quitar-apps) QUITAR_APPS=1 ;;
    --optimizar) OPTIMIZAR=1 ;;
    --cerrar-adb) CERRAR_ADB=1 ;;
    --sin-apps) APPS=0 ;;
    --sin-launcher) LAUNCHER=0 ;;
    --zona) ZONA=${2:-}; shift ;;
    --sin-reinicio) REINICIAR=0 ;;
    -h|--ayuda|--help) ayuda; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; ayuda; exit 2 ;;
  esac
  shift
done

paso() { printf '\n\033[1m%s\033[0m\n' "$*"; }
aviso() { printf '  %s\n' "$*"; }
fallar() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

for c in adb nc curl; do
  command -v $c >/dev/null || fallar "Falta '$c'. En macOS: brew install android-platform-tools. En Linux: apt install adb netcat-openbsd."
done
[ -f "$DIR/dispositivo.sh" ] && [ -f "$DIR/indicadores.txt" ] || fallar "Faltan dispositivo.sh o indicadores.txt junto a este script."

# Corre un comando con tope de segundos (macOS no trae `timeout`).
con_limite() {
  local s=$1; shift
  "$@" & local pid=$!
  ( sleep "$s"; kill "$pid" 2>/dev/null ) & local vigia=$!
  wait "$pid" 2>/dev/null; local r=$?
  kill "$vigia" 2>/dev/null; wait "$vigia" 2>/dev/null
  return $r
}

# Los primeros tres números de la IP de esta computadora (192.168.0, por ejemplo).
subred() {
  local ip=""
  if command -v ip >/dev/null; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')
  fi
  if [ -z "$ip" ] && command -v route >/dev/null; then
    local interfaz
    interfaz=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
    [ -n "$interfaz" ] && ip=$(ipconfig getifaddr "$interfaz" 2>/dev/null)
  fi
  echo "${ip%.*}"
}

# Imprime las IP con el ADB abierto en la red, una por línea: las que se anuncian por mDNS y
# las que responden en el puerto.
buscar() {
  {
    adb mdns services 2>/dev/null | awk '/_adb._tcp/ {split($3, a, ":"); print a[1]}'
    local base; base=$(subred)
    if [ -n "$base" ]; then
      for i in $(seq 1 254); do
        ( nc -z -w 1 "$base.$i" $PUERTO >/dev/null 2>&1 && echo "$base.$i" ) &
      done
      wait
    fi
  } | sort -u
}

encontrar_equipo() {
  if [ -n "$IP" ] && [ $ESPERAR = 0 ]; then return; fi
  local limite=1
  [ $ESPERAR = 1 ] && limite=100
  [ $ESPERAR = 1 ] && aviso "Esperando a que abra el ADB (hasta 5 minutos)…"
  for _ in $(seq 1 $limite); do
    if [ -n "$IP" ]; then
      nc -z -w 1 "$IP" $PUERTO >/dev/null 2>&1 && return
    else
      local halladas; halladas=$(buscar)
      case $(echo "$halladas" | grep -c .) in
        0) ;;
        1) IP=$halladas; return ;;
        *) fallar "Hay más de un equipo con ADB en la red; elegí cuál con --ip:
$(echo "$halladas" | sed 's/^/  /')" ;;
      esac
    fi
    [ $limite -gt 1 ] && sleep 3
  done
  [ -z "$IP" ] && fallar "No encontré ningún equipo con ADB abierto en la red. ¿Está activada la depuración? ¿Probaste con --esperar justo después de prenderlo?"
  fallar "El equipo $IP no tiene el ADB abierto."
}

conectar() {
  D="$IP:$PUERTO"
  adb disconnect "$D" >/dev/null 2>&1
  con_limite 10 adb connect "$D" >/dev/null 2>&1
  local estado
  for _ in $(seq 1 30); do
    estado=$(adb devices | awk -v d="$D" '$1 == d {print $2}')
    case $estado in
      device) return 0 ;;
      unauthorized) aviso "En la tele apareció \"¿Permitir la depuración?\": aceptalo con el control." ;;
      *) con_limite 10 adb connect "$D" >/dev/null 2>&1 ;;
    esac
    sleep 2
  done
  return 1
}

# Comando como root, por su o por `adb root`. Sin comillas simples adentro.
ROOT=""
rsh() {
  if [ "$ROOT" = su ]; then adb -s "$D" shell "su -c '$1'"
  else adb -s "$D" shell "$1"
  fi
}

detectar_root() {
  if adb -s "$D" shell "su -c id" 2>/dev/null | grep -q 'uid=0'; then ROOT=su; return 0; fi
  if adb -s "$D" shell id 2>/dev/null | grep -q 'uid=0'; then ROOT=adb; return 0; fi
  if adb -s "$D" root 2>/dev/null | grep -qiE 'restarting|already'; then
    sleep 3
    conectar && adb -s "$D" shell id | grep -q 'uid=0' && { ROOT=adb; return 0; }
  fi
  return 1
}

# Lo primero apenas se entra: frenar los servicios conocidos, que cierran el ADB al rato.
frenar_conocidos() {
  local servicios
  servicios=$(grep -E '^servicio[[:space:]]' "$DIR/indicadores.txt" | sed -E 's/#.*//' | awk '{print $2}' | tr '\n' ' ')
  [ -z "$servicios" ] && return
  rsh "for s in $servicios; do setprop ctl.stop \$s; for p in \$(pidof \$s); do kill -9 \$p; done; done" >/dev/null 2>&1
}

reconectar() {
  adb disconnect "$D" >/dev/null 2>&1
  con_limite 10 adb connect "$D" >/dev/null 2>&1
}

# Sigue el informe a medida que dispositivo.sh lo escribe, reconectando si el ADB se corta.
seguir_informe() {
  local vistas=0 total t=0
  while [ $t -lt 1800 ]; do
    sleep 4; t=$((t + 4))
    if ! adb -s "$D" shell true >/dev/null 2>&1; then reconectar; continue; fi
    total=$(adb -s "$D" shell "cat $REMOTO/informe.txt 2>/dev/null | wc -l" | tr -dc '0-9')
    if [ -n "$total" ] && [ "$total" -gt "$vistas" ]; then
      adb -s "$D" shell "sed -n '$((vistas + 1)),${total}p' $REMOTO/informe.txt" | tr -d '\r' | sed 's/^/  /'
      vistas=$total
    fi
    adb -s "$D" shell "ls $REMOTO/listo 2>/dev/null" | grep -q listo && return 0
  done
  return 1
}

# Captura de la pantalla de la tele, para el antes y el después.
capturar() {
  adb -s "$D" exec-out screencap -p > "$SALIDA/$1.png" 2>/dev/null && aviso "Captura: $SALIDA/$1.png"
}

instalado() {
  adb -s "$D" shell "pm path $1" 2>/dev/null | grep -q package:
}

# El WebView de fábrica de estos equipos es viejísimo (Chrome 66 a 93): las apps y las páginas
# modernas se ven rotas. Se instala el de Google 138, el último para Android 8 y 9. No hace
# falta verificar la descarga: Android solo acepta la actualización si viene firmada como el
# WebView de Google que trae el sistema.
instalar_webview() {
  local v sdk abi
  v=$(adb -s "$D" shell "dumpsys package com.google.android.webview | grep -m1 versionName" | tr -d '\r' | sed 's/.*=//')
  sdk=$(adb -s "$D" shell getprop ro.build.version.sdk | tr -dc '0-9')
  abi=$(adb -s "$D" shell getprop ro.product.cpu.abi | tr -d '\r')
  if [ "${v%%.*}" -ge 100 ] 2>/dev/null; then aviso "✓ WebView $v, al día"; return; fi
  if [ "$sdk" != 26 ] && [ "$sdk" != 27 ] && [ "$sdk" != 28 ]; then aviso "WebView: no es Android 8 o 9 (sdk $sdk); lo dejo como está."; return; fi
  if [ "$abi" != armeabi-v7a ]; then aviso "WebView: procesador $abi; esta versión es para armeabi-v7a, lo dejo como está."; return; fi

  aviso "WebView $v: bajando el 138 de Google (91 MB)…"
  # APKPure entrega un enlace firmado por pedido; el código de versión 720417900 es armeabi-v7a.
  local url apk="$SALIDA/webview.apk"
  url=$(curl -s --max-time 30 'https://api.pureapk.com/m/v3/cms/app_version?hl=en-US&package_name=com.google.android.webview' \
        -H 'x-cv: 3172501' -H "x-sv: $sdk" -H 'x-abis: armeabi-v7a,armeabi' -H 'x-gp: 1' \
      | LC_ALL=C grep -aoE 'https://data\.winudf\.com/APK/Y29tLmdvb2dsZS5hbmRyb2lkLndlYnZpZXdfNzIwNDE3OTAw[A-Za-z0-9]*\?filename=[^&]*&k=[0-9a-f]+&package_name=com\.google\.android\.webview&token=[0-9]+-[0-9a-f]+-[0-9]+-[0-9a-f]{32}' | head -1)
  if [ -z "$url" ] || ! curl -sL --max-time 600 -o "$apk" "$url"; then aviso "WebView: no pude bajarlo; lo dejo como está."; return; fi

  adb -s "$D" push "$apk" /data/local/tmp/webview.apk >/dev/null 2>&1 || { aviso "WebView: no pude copiarlo al equipo."; return; }
  rm -f "$apk"
  # Android 9 le desinstala la actualización al WebView si Chrome también sirve de WebView
  # ("fallback logic"); hay que apagar eso antes de instalar.
  adb -s "$D" shell "cmd webviewupdate enable-redundant-packages" >/dev/null 2>&1
  # Instalado desde adentro y en segundo plano: un APK grande corta el ADB por Wi-Fi.
  adb -s "$D" shell "rm -f /data/local/tmp/webview.log; nohup sh -c 'pm install -r -d /data/local/tmp/webview.apk > /data/local/tmp/webview.log 2>&1; echo FIN >> /data/local/tmp/webview.log' >/dev/null 2>&1 &" >/dev/null 2>&1
  local r=""
  for _ in $(seq 1 60); do
    sleep 5
    r=$(adb -s "$D" shell "cat /data/local/tmp/webview.log 2>/dev/null" | tr -d '\r')
    case $r in *FIN*) break ;; "") reconectar ;; esac
  done
  adb -s "$D" shell "rm -f /data/local/tmp/webview.apk /data/local/tmp/webview.log" >/dev/null 2>&1
  case $r in *Success*) ;; *) aviso "WebView: Android no lo aceptó (${r%%FIN*}); queda el de fábrica."; return ;; esac
  adb -s "$D" shell "pm enable com.google.android.webview; cmd webviewupdate set-webview-implementation com.google.android.webview; pm disable-user --user 0 com.android.chrome" >/dev/null 2>&1
  aviso "✓ WebView 138 instalado y activo (Chrome viejo desactivado)"
}

# TV Bro: navegador para el control remoto, desde su página oficial en GitHub. La versión sin
# motor propio usa el WebView del sistema: pesa 7 MB en vez de 60.
instalar_tvbro() {
  instalado com.phlox.tvwebbrowser && { aviso "✓ TV Bro ya estaba"; return; }
  local apk="$SALIDA/tvbro.apk"
  if curl -sL --max-time 300 -o "$apk" https://github.com/truefedex/tv-bro/releases/download/v2.1.6/tvbro-2.1.6-generic-geckoExcluded.apk \
     && con_limite 180 adb -s "$D" install -r "$apk" >/dev/null 2>&1; then
    aviso "✓ TV Bro instalado"
  else
    aviso "TV Bro: no pude instalarlo."
  fi
  rm -f "$apk"
}

# Spotify y TuneIn vienen del Play Store del equipo: se abre su página y se espera a que alguien
# apriete Instalar con el control. Hace falta una cuenta de Google iniciada.
instalar_de_la_tienda() {
  local pkg=$1 nombre=$2
  instalado "$pkg" && { aviso "✓ $nombre ya estaba"; return; }
  adb -s "$D" shell "am start -a android.intent.action.VIEW -d market://details?id=$pkg" >/dev/null 2>&1
  aviso "En la tele: apretá Instalar en $nombre (espero hasta 4 minutos)…"
  for _ in $(seq 1 48); do
    sleep 5
    instalado "$pkg" && { aviso "✓ $nombre instalado"; return; }
  done
  aviso "$nombre: no se instaló; queda para después, desde el Play Store."
}

instalar_apps() {
  adb -s "$D" shell "pm enable com.android.vending" >/dev/null 2>&1
  instalar_webview
  instalar_tvbro
  instalar_de_la_tienda com.spotify.tv.android Spotify
  instalar_de_la_tienda tunein.player TuneIn
  adb -s "$D" shell "input keyevent HOME" >/dev/null 2>&1
}

# Vidrio Launcher: liviano, sin publicidad ni recomendaciones, en apks/. Queda como pantalla de
# inicio; el permiso DUMP es para su tarjeta de música en equipos que se declaran de poca memoria.
instalar_launcher() {
  local apk="$DIR/apks/vidrio-launcher.apk"
  [ -f "$apk" ] || { aviso "No está apks/vidrio-launcher.apk; sigo sin launcher."; return; }
  if ! con_limite 120 adb -s "$D" install -r "$apk" >/dev/null 2>&1; then
    aviso "No pude instalar Vidrio Launcher; el resto de la limpieza quedó hecho."
    return
  fi
  # Los launchers de fábrica se desactivan (reversible con pm enable): si no, después de
  # reiniciar Android puede volver a elegirlos. Configuración tiene su propia pantalla de
  # inicio de respaldo, así que el equipo nunca queda sin una.
  local otros p
  otros=$(adb -s "$D" shell "cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.HOME" 2>/dev/null \
    | tr -d '\r' | awk -F= '/^ +packageName=/ {print $2}' | sort -u)
  for p in $otros; do
    case $p in com.augusto.vidrio|com.android.tv.settings|com.android.settings|android) continue ;; esac
    adb -s "$D" shell "pm disable-user --user 0 $p" >/dev/null 2>&1 && aviso "Launcher de fábrica desactivado: $p (se revierte con: pm enable $p)"
  done
  adb -s "$D" shell "cmd package set-home-activity com.augusto.vidrio/.MainActivity" >/dev/null 2>&1
  adb -s "$D" shell "pm grant com.augusto.vidrio android.permission.DUMP" >/dev/null 2>&1
  adb -s "$D" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME" >/dev/null 2>&1
  aviso "✓ Vidrio Launcher instalado y elegido como pantalla de inicio."
}

# ---------------------------------------------------------------------------------------------
paso "1. Buscando el equipo"
encontrar_equipo
aviso "Equipo en $IP"
conectar || fallar "No pude conectarme a $IP:$PUERTO."

paso "2. Acceso root"
detectar_root || fallar "El equipo no da root (ni su ni adb root). Este script está pensado para TV box genéricos con firmware de fábrica, que lo traen."
aviso "Root por: $ROOT"
frenar_conocidos

MODELO=$(adb -s "$D" shell getprop ro.product.model | tr -d '\r' | tr -c 'A-Za-z0-9_-' '_')
SALIDA="$DIR/informes/$(date +%Y%m%d-%H%M)-${MODELO:-equipo}"
mkdir -p "$SALIDA"
capturar antes

paso "3. $( [ $MODO = limpiar ] && echo Limpiando || echo Analizando ) (corre dentro del equipo; si el ADB se corta, sigue igual)"
rsh "rm -rf $REMOTO; mkdir -p $REMOTO; chmod 777 $REMOTO" >/dev/null
adb -s "$D" push "$DIR/dispositivo.sh" "$DIR/indicadores.txt" "$REMOTO/" >/dev/null || fallar "No pude copiar los scripts al equipo."
rsh "nohup sh $REMOTO/dispositivo.sh $MODO $QUITAR_APPS $OPTIMIZAR $CERRAR_ADB >/dev/null 2>&1 &" >/dev/null 2>&1
seguir_informe || aviso "No terminó en 30 minutos; el informe parcial queda igual."

paso "4. Trayendo el informe"
adb -s "$D" pull "$REMOTO/informe.txt" "$SALIDA/" >/dev/null 2>&1
if [ $MODO = limpiar ]; then
  adb -s "$D" pull "$REMOTO/cuarentena" "$SALIDA/" >/dev/null 2>&1
fi
rsh "rm -rf $REMOTO" >/dev/null 2>&1
aviso "Informe: $SALIDA/informe.txt"
[ -d "$SALIDA/cuarentena" ] && aviso "Copias de lo modificado: $SALIDA/cuarentena"

if [ $MODO = analizar ]; then
  paso "Listo. No se modificó nada."
  aviso "Para limpiar: ./limpiar-tvbox.sh --limpiar --ip $IP"
  exit 0
fi

if [ -n "$ZONA" ]; then
  rsh "settings put global auto_time 1; settings put global auto_time_zone 0; setprop persist.sys.timezone $ZONA; service call alarm 3 s16 $ZONA" >/dev/null 2>&1
  aviso "Zona horaria: $ZONA"
fi

if [ $APPS = 1 ]; then
  paso "5. Apps de base"
  instalar_apps
fi

if [ $LAUNCHER = 1 ]; then
  paso "6. Instalando Vidrio Launcher"
  instalar_launcher
fi

if [ $REINICIAR = 1 ]; then
  paso "7. Reiniciando para verificar"
  adb -s "$D" reboot >/dev/null 2>&1
  sleep 25
  # Si la MAC no se pudo fijar, puede volver con otra IP.
  ANTERIOR=$IP; IP=""; ESPERAR=1
  nc -z -w 1 "$ANTERIOR" $PUERTO >/dev/null 2>&1 && IP=$ANTERIOR
  encontrar_equipo
  conectar && detectar_root || fallar "Después del reinicio no pude volver a entrar. Revisá $SALIDA/informe.txt."
  sleep 20

  servicios=$(grep -E '^servicio[[:space:]]' "$DIR/indicadores.txt" | sed -E 's/#.*//' | awk '{print $2}')
  bien=1
  for s in $servicios; do
    if [ -n "$(rsh "pidof $s" | tr -d '\r')" ]; then aviso "✗ $s volvió a arrancar"; bien=0
    else aviso "✓ $s no arrancó"; fi
  done
  restos=$(rsh "ls /data/adb 2>/dev/null" | tr -d '\r')
  for e in $(grep -E '^adb[[:space:]]' "$DIR/indicadores.txt" | sed -E 's/#.*//' | awk '{print $2}'); do
    echo "$restos" | grep -qxE "$e(\.tar|\.lock)?" && { aviso "✗ /data/adb/$e reapareció"; bien=0; }
  done
  [ $bien = 1 ] && aviso "✓ /data/adb sin proxyware"
  [ "$IP" != "$ANTERIOR" ] && aviso "Volvió con otra IP: $IP"
fi

if [ $CERRAR_ADB = 1 ]; then
  paso "Cerrando el ADB por red"
  rsh "settings put global adb_enabled 0" >/dev/null 2>&1
  aviso "Para volver a entrar: Opciones de desarrollador → Depuración USB."
fi

adb -s "$D" shell "input keyevent HOME" >/dev/null 2>&1
sleep 8
capturar despues

paso "Listo."
aviso "Si el equipo tuvo cuentas iniciadas (Google, Netflix, etc.), cambiá esas contraseñas desde otro dispositivo."
