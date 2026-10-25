# limpiar-tvbox

Analiza y limpia los **TV box Android genéricos** (los "Android 14 / 8 GB de RAM" baratos de marketplace, con chip Amlogic o Rockchip) que vienen con **malware de fábrica**. Corre desde una computadora con macOS o Linux y maneja el equipo por ADB. Por defecto solo mira; con `--limpiar`, limpia y deja el equipo listo para usar.

> *English: a script to audit and clean generic Android TV boxes that ship with a preinstalled residential-proxy botnet (BadBox-like). Runs from macOS/Linux over ADB. Analysis is read-only by default.*

## Por qué lo hice

Compré un TV stick genérico, un **TVR3-s**, de esos que se venden como "Android 14, 8 GB de RAM, 4K". Quería entrar por ADB para configurarlo, y la conexión se cortaba sola uno o dos minutos después de cada arranque. Investigando por qué, encontré que el equipo traía de fábrica, con permisos de root, un programa que **alquilaba mi conexión a internet a desconocidos**.

No era un caso aislado. En 2025 el FBI advirtió que millones de estos equipos genéricos salen de fábrica infectados (la familia **BadBox**) y se usan como red de proxies residenciales: el tráfico de otros sale por tu casa, con tu IP. Si alguien comete un fraude a través de esa red, lo que queda registrado es tu conexión.

Limpié el mío a mano y después armé este script para hacer lo mismo con un segundo equipo, y para que cualquiera con uno de estos aparatos pueda revisarlo sin tener que repetir todo el proceso.

## Qué encontré en el TVR3-s

Placa Amlogic S905X/W (`gxl_p212_1g`), comprada en 2026.

| Qué | Dónde | Qué hacía |
|---|---|---|
| `daemon12138` | `/system/bin`, arranca con el sistema como root | Programa en Go que se reporta a servidores de control (`ooyy.online`, `pansy.pw`, `aibigdatausa.com`), ofrece la conexión como proxy (servicio "ipfly"), maneja un Chrome oculto y baja los programas de la fila siguiente. Además **cierra el ADB** al rato de arrancar, para que nadie lo vea. |
| CastarSdk, EarnFM, Pawns, PacketStream, Honeygain, Traffmonetizer | `/data/adb`, **933 MB** | Programas que pagan por usar tu ancho de banda. El que cobra no sos vos. |
| `com.oranth.accessibility` | app de sistema | Registra un servicio de accesibilidad, que puede leer y tocar la pantalla. |
| `io.rkupdates`, `com.droidlogic.otaupgrade` | apps de sistema | "Actualizadores" que pueden devolver el malware con una supuesta actualización. Uno es de Rockchip en un equipo Amlogic. |
| `com.DeviceTest`, `com.khy.videotest` | apps de sistema | Apps de prueba de fábrica que arrancan solas en cada inicio. |
| Magis TV y 12 APK más | `/system/preinstall` | Se reinstalan después de cada reset de fábrica. |
| Verificación de internet | configuración | Apuntaba a `captive.v2ex.co` en vez de al servidor de Google. |

Y además, **el equipo miente**:

- Dice ser Android 14 y es **Android 9**. Se presenta como un Pixel 2 para pasar los controles de Google.
- Reporta **8 GB de RAM** y la placa tiene **1 GB**.
- Es una compilación de desarrollo (`userdebug`, `test-keys`), con SELinux desactivado y un `su` que **le da root a cualquier app sin preguntar**.
- El navegador interno (WebView) era de 2018, así que las páginas modernas se veían rotas.
- Inventaba una dirección MAC distinta en cada arranque, así que cambiaba de IP todo el tiempo.

## Qué significa si tenés uno

- Tu conexión puede estar siendo usada por otros: más lenta, y tu IP mezclada en lo que sea que hagan.
- Cualquier cuenta que hayas iniciado en el equipo (Google, Netflix, etc.) estuvo al alcance de un programa con root. **Cambiá esas contraseñas desde otro dispositivo.**
- Un reset de fábrica **no alcanza**: el malware vive en la partición del sistema y se reinstala solo.

## Qué hace el script

Por defecto **solo analiza**: frena el malware hasta el próximo reinicio (para que no corte la conexión) y arma un informe. No modifica nada.

Con `--limpiar`:

1. **Neutraliza** los servicios maliciosos: los frena, renombra el binario a `.disabled` sin permiso de ejecución y comenta su arranque. No lo borra.
2. **Borra el proxyware** de `/data/adb`, solo las entradas listadas en `indicadores.txt`. Lo que no reconoce (por ejemplo Magisk) lo informa y no lo toca. Antes de borrar, desmonta lo que el malware montó adentro.
3. **Desactiva** las apps de sistema sospechosas (`pm disable`, reversible con `pm enable`).
4. **Borra las APK de preinstalación**, para que un reset de fábrica no devuelva las apps piratas.
5. Vuelve a poner la **verificación de internet** de Google, si el fabricante la cambió por otra.
6. **Fija la MAC del Wi-Fi** si el driver lo permite.
7. **Instala las apps de base:** el WebView 138 de Google si el de fábrica es viejo (con el arreglo para que Android 9 no lo desinstale solo), TV Bro desde su página oficial, y Spotify y TuneIn desde el Play Store de la tele, donde hay que apretar Instalar con el control. Se evita con `--sin-apps`.
8. **Instala [Vidrio Launcher](apks/)** y lo deja como pantalla de inicio: un launcher liviano (60 KB), sin publicidad ni recomendaciones, con reloj, clima, fútbol en vivo y fondos de astronomía. Se evita con `--sin-launcher`.
9. **Reinicia y verifica** que nada haya vuelto.

Saca una captura de la tele al empezar y otra al terminar (`antes.png` y `despues.png`). Todo archivo que modifica se copia antes a `informes/<fecha>-<equipo>/cuarentena/` en tu computadora.

Opcionales: `--quitar-apps` (desinstala todas las apps no del sistema), `--optimizar` (animaciones más rápidas, TalkBack apagado si no se usa) y `--cerrar-adb` (al final cierra el ADB por red; abierto, cualquiera en tu Wi-Fi puede tener root en el equipo).

## Requisitos

- macOS o Linux con `adb`, `nc` y `curl`:
  - macOS: `brew install android-platform-tools`
  - Debian/Ubuntu: `sudo apt install adb netcat-openbsd curl`
  - Windows: usalo desde WSL.
- La computadora y el TV box **en la misma red**.
- En el TV box: **Ajustes → Preferencias del dispositivo → Información**, tocar 7 veces "Compilación" para habilitar las opciones de desarrollador; después, en **Opciones de desarrollador**, activar **Depuración USB**. En estos equipos eso alcanza para que el ADB se abra por Wi-Fi, a veces recién después de reiniciar.
- Para Spotify y TuneIn, una cuenta de Google iniciada en el Play Store del equipo. Mejor una secundaria (ver Limitaciones).

## Uso

```bash
git clone https://github.com/4u6u570/limpiar-tvbox
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
- **El firmware sigue siendo el del fabricante**: Android viejo, sin parches de seguridad, con SELinux apagado y con un `su` que da root a cualquier app. Limpio sirve para ver contenido; **no inicies sesión con tus cuentas importantes** y usá una cuenta de Google secundaria.
- Necesita root. Estos equipos lo traen de fábrica (`su` o compilación `userdebug`); si el tuyo no, el script no sigue.
- Está probado en un TVR3-s (Amlogic S905X/W, placa `gxl_p212_1g`, Android 9). En otros modelos el análisis funciona igual; la limpieza solo actúa sobre lo que reconoce.

## Si encontrás algo nuevo

Corré el análisis, mirá el informe y sumá lo que encuentres a [`indicadores.txt`](indicadores.txt): servicios, paquetes, carpetas de `/data/adb` o dominios. El formato está explicado en el mismo archivo. Los pull requests son bienvenidos; incluí el modelo del equipo y la parte del informe que lo muestra.

## Cómo deshacer

- Apps desactivadas: `adb shell su -c 'pm enable <paquete>'`.
- Servicios neutralizados: el original está en la cuarentena; volvé a copiarlo a su ruta y descomentá su `start` en el `.rc`.
- Lo borrado de `/data/adb` y las APK de preinstalación no se recuperan (es el malware).
- Vidrio Launcher se desinstala como cualquier app; Android vuelve a ofrecer el launcher de fábrica.

## Licencia

MIT. Ver [LICENSE](LICENSE). Se usa sin garantía: el script modifica la partición del sistema de un equipo que no controlás del todo.
