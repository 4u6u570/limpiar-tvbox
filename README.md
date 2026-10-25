# limpiar-tvbox

Analiza y limpia los **TV box Android genéricos** (los "Android 14 / 8 GB de RAM" de marketplace, con chip Amlogic o Rockchip) que vienen con **malware de fábrica**. Esos equipos suelen traer un servicio con permisos de root que **revende tu conexión a internet** a terceros (proxy residencial), hace clics en publicidad con un navegador oculto y baja más software sin avisar. Suelen venir con apps como Magis TV preinstaladas.

> *English: a script to audit and clean generic Android TV boxes that ship with a preinstalled residential-proxy botnet (BadBox-like). Runs from macOS/Linux over ADB. Analysis is read-only by default.*

## Qué encontramos en un TVR3-s (Amlogic S905W, "Android 14")

| Qué | Dónde | Qué hacía |
|---|---|---|
| `daemon12138` | `/system/bin`, arranca con el sistema como root | Se reporta a servidores de control, ofrece la conexión como proxy ("ipfly"), maneja un Chrome oculto, baja los SDK de abajo y **cierra el ADB** al rato de arrancar |
| CastarSdk, EarnFM, Pawns, PacketStream, Honeygain, Traffmonetizer | `/data/adb` (~930 MB) | SDK que pagan por usar tu ancho de banda |
| `com.oranth.accessibility` y otras | apps de sistema | Servicio de accesibilidad (puede leer y tocar la pantalla), "actualizador" de Rockchip, apps de test que arrancan solas |
| Magis TV y 12 APK más | `/system/preinstall` | Se reinstalan después de cada reset de fábrica |

Además, el equipo **miente**: dice Android 14 y es Android 9; reporta 8 GB de RAM y la placa tiene 1 GB.

## Qué hace el script

Por defecto **solo analiza**: frena el malware hasta el próximo reinicio (para que no corte la conexión) y arma un informe. No modifica nada.

Con `--limpiar`:

1. **Neutraliza** los servicios maliciosos: los frena, renombra el binario a `.disabled` sin permiso de ejecución y comenta su arranque. No lo borra.
2. **Borra el proxyware** de `/data/adb`, solo las entradas listadas en `indicadores.txt`. Lo que no reconoce (por ejemplo Magisk) lo informa y no lo toca. Antes de borrar desmonta lo que el malware montó adentro.
3. **Desactiva** las apps de sistema sospechosas (`pm disable`, reversible con `pm enable`).
4. **Borra las APK de preinstalación**, para que un reset de fábrica no devuelva las apps piratas.
5. Vuelve a poner la **verificación de internet** de Google, si el fabricante la cambió por otra.
6. **Fija la MAC del Wi-Fi** si el driver lo permite. Algunos equipos inventan una MAC en cada arranque y cambian de IP.
7. **Instala [Vidrio Launcher](apks/)** y lo deja como pantalla de inicio: un launcher liviano (60 KB), sin publicidad ni recomendaciones, con reloj, clima, fútbol en vivo y fondos de astronomía. Se evita con `--sin-launcher`.
8. **Reinicia y verifica** que nada haya vuelto.

Todo archivo que modifica se copia antes a `informes/<fecha>-<equipo>/cuarentena/` en tu computadora.

Opcionales: `--quitar-apps` (desinstala todas las apps no del sistema), `--optimizar` (animaciones más rápidas, TalkBack apagado si no se usa) y `--cerrar-adb` (al final cierra el ADB por red; abierto, cualquiera en tu Wi-Fi puede tener root en el equipo).

## Requisitos

- macOS o Linux con `adb` y `nc`:
  - macOS: `brew install android-platform-tools`
  - Debian/Ubuntu: `sudo apt install adb netcat-openbsd`
  - Windows: usalo desde WSL.
- La computadora y el TV box **en la misma red**.
- En el TV box: **Ajustes → Preferencias del dispositivo → Información**, tocar 7 veces "Compilación" para habilitar las opciones de desarrollador; después, en **Opciones de desarrollador**, activar **Depuración USB**. En estos equipos eso alcanza para que el ADB se abra por Wi-Fi, a veces recién después de reiniciar.

## Uso

```bash
git clone https://github.com/<usuario>/limpiar-tvbox
cd limpiar-tvbox

# 1. Mirar primero (no cambia nada)
./limpiar-tvbox.sh

# 2. Limpiar
./limpiar-tvbox.sh --limpiar

# Limpieza completa, dejándolo cerrado
./limpiar-tvbox.sh --limpiar --quitar-apps --optimizar --cerrar-adb
```

**Si no lo encuentra:** el malware cierra el ADB uno o dos minutos después de arrancar. Corré el script con `--esperar`, **después reiniciá el equipo**, y entra apenas se abre la ventana.

**Si en tu red hay más de un equipo con ADB**, pasale cuál con `--ip 192.168.x.x`. La IP está en Ajustes → Red.

## Limitaciones (leelas)

- **No es una garantía.** Detecta lo que está en `indicadores.txt` y los programas que contienen direcciones de servidores sospechosos. Hay malware conocido (Triada, variantes de BadBox) que vive dentro del framework de Android y oculta sus direcciones; esto no lo ve.
- **El firmware sigue siendo el del fabricante**: Android viejo, sin parches de seguridad y con SELinux apagado. Limpio sirve para ver contenido; **no inicies sesión con tus cuentas importantes**. Si ya lo hiciste, cambiá esas contraseñas desde otro dispositivo.
- Necesita root. Estos equipos lo traen de fábrica (`su` o compilación `userdebug`); si el tuyo no, el script no sigue.
- Está probado en un TVR3-s (Amlogic S905X/W, placa `gxl_p212_1g`, Android 9). En otros modelos el análisis funciona igual; la limpieza solo actúa sobre lo que reconoce.

## Si encontrás algo nuevo

Corré el análisis, mirá el informe y sumá lo que encuentres a [`indicadores.txt`](indicadores.txt): servicios, paquetes, carpetas de `/data/adb` o dominios. El formato está explicado en el mismo archivo. Los pull requests son bienvenidos; incluí el modelo del equipo y la parte del informe que lo muestra.

## Cómo deshacer

- Apps desactivadas: `adb shell su -c 'pm enable <paquete>'`.
- Servicios neutralizados: el original está en la cuarentena; volvé a copiarlo a su ruta y descomentá su `start` en el `.rc`.
- Lo borrado de `/data/adb` y las APK de preinstalación no se recuperan (es el malware).

## Licencia

MIT. Ver [LICENSE](LICENSE).
