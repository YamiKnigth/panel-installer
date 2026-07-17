# Pterodactyl Installer para Multipass

Herramienta en Bash para instalar, actualizar, respaldar y restaurar despliegues de Pterodactyl sobre Ubuntu 24.04 dentro de instancias Multipass. Está orientada a dos escenarios:

- Panel local y Wings local en la misma instancia.
- Panel local en una instancia y Wings remoto en otra instancia distinta.

La automatización está pensada específicamente para Ubuntu 24.04 nativo, evitando PPAs externos para PHP, MariaDB o Redis.

## Qué hace la herramienta

El menú principal expone estas operaciones:

1. Instalar Panel Pterodactyl.
2. Instalar Pterodactyl Wings.
3. Crear respaldo (solo Panel, Panel + Wings, o solo Wings).
4. Actualizar Panel Pterodactyl con respaldo previo.
5. Actualizar Pterodactyl Wings con respaldo previo.
6. Restaurar un respaldo generado por esta herramienta.
7. Salir.

Además:

- Detecta varias IPs de la instancia y te deja elegir la correcta, algo clave en Multipass sobre macOS y Windows.
- Instala PHP 8.2 o 8.3, MariaDB, Redis y Nginx desde los repositorios oficiales de Ubuntu 24.04, alineado con la documentación oficial del panel.
- Genera credenciales aleatorias para el panel y la base de datos, guardadas en `/root/credenciales_pterodactyl.txt`.
- Registra Wings directamente en la base de datos del panel (bypass del API HTTP) para evitar fallos por proxy o 404, cifrando el `daemon_token` con el mismo formato que usa el modelo `Node` del panel para poder decodificarlo.
- Pre-descarga la imagen `ghcr.io/pterodactyl/installers:alpine` que Wings necesita para instalar cualquier servidor — sin ella, la creación de servidores se queda "instalando" indefinidamente.
- Abre en `ufw` (si está activo) los puertos de la API de Wings, SFTP y la primera allocation creada.
- Verifica que el servicio `wings` haya quedado activo tras instalarlo/actualizarlo; si falla, muestra el log y aborta en vez de reportar éxito falso.
- Genera respaldos reales con mysqldump, `.env` del panel y `config.yml` de Wings; la subida a un host público es siempre opcional y se confirma de forma interactiva.
- Permite restaurar esos respaldos desde una URL o desde un archivo zip local, verificando primero que el UUID del nodo restaurado siga existiendo en la base de datos actual del panel antes de reiniciar Wings.

## Requisitos

- macOS o Windows con privilegios para instalar Multipass.
- Multipass instalado.
- Una o más instancias Ubuntu 24.04.
- Acceso con sudo dentro de la instancia.
- Conectividad a Internet desde la instancia.
- Si vas a instalar Wings remoto: acceso de red desde el nodo hacia MariaDB del servidor del panel.

## Preparación en macOS

### 1. Instalar Multipass

Instala Multipass desde la documentación oficial de Canonical o con Homebrew:

```bash
brew install --cask multipass
```

Verifica:

```bash
multipass version
```

### 2. Crear una instancia Ubuntu 24.04 para el panel

```bash
multipass launch 24.04 --name ptero-panel --cpus 4 --memory 8G --disk 50G
```

Si quieres un nodo remoto adicional:

```bash
multipass launch 24.04 --name ptero-wings --cpus 4 --memory 8G --disk 80G
```

### 3. Comprobar IPs detectadas por Multipass

```bash
multipass list
```

Si tu entorno usa bridge o vmnet y aparecen varias interfaces, no elijas la IP manualmente todavía: el instalador listará todas las IPs de la instancia para que selecciones la correcta dentro de Ubuntu.

### 4. Entrar a la instancia

```bash
multipass shell ptero-panel
```

## Preparación en Windows

### 1. Instalar Multipass

Instálalo desde la web oficial de Canonical. En Windows normalmente se apoyará en Hyper-V o en el backend disponible en tu equipo.

Verifica en PowerShell:

```powershell
multipass version
```

### 2. Crear una instancia Ubuntu 24.04 para el panel

```powershell
multipass launch 24.04 --name ptero-panel --cpus 4 --memory 8G --disk 50G
```

Nodo remoto opcional:

```powershell
multipass launch 24.04 --name ptero-wings --cpus 4 --memory 8G --disk 80G
```

### 3. Consultar las instancias

```powershell
multipass list
```

### 4. Entrar a la instancia

```powershell
multipass shell ptero-panel
```

## Instancia ligera para pruebas rápidas (smoke test)

Si solo quieres validar que el instalador funciona de punta a punta (panel + Wings en una sola instancia) sin dedicar los recursos de una instancia de producción, puedes crear una instancia combinada más pequeña:

```bash
multipass launch 24.04 --name ptero-test --cpus 2 --memory 2G --disk 5G
```

Instala primero el panel y luego Wings en modo "panel local" dentro de esa misma instancia (opción 1 al preguntar por el tipo de panel).

**Advertencia:** 2 GB de RAM y 5 GB de disco son un límite muy ajustado para correr simultáneamente MariaDB, PHP-FPM, Redis, Nginx, Docker y Wings. Esta configuración es únicamente para pruebas de humo cortas (crear el panel, registrar un nodo, confirmar que arranca) — no la uses para producción ni para pruebas de carga.

## Preparación recomendada dentro de Ubuntu 24.04

Actualiza la instancia antes de correr el instalador:

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

Si vas a usar un panel con Wings remoto, asegúrate de definir antes estos puntos en la instancia del panel:

- Un dominio o IP estable para el panel.
- Acceso de MariaDB desde la IP del nodo remoto.
- Reglas de firewall para HTTP/HTTPS, puerto de Wings y MariaDB si realmente vas a abrirlo entre instancias.

Si necesitas acceso remoto a MariaDB para registrar Wings desde otra instancia, debes ajustar la configuración de MariaDB de forma controlada para permitir la IP exacta del nodo remoto y no una red completa sin restricciones.

## Ejecutar la herramienta

Puedes usarla sin clonar el repositorio:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/YamiKnigth/panel-installer/main/install.sh)
```

O clonar el repositorio y ejecutarla localmente:

```bash
git clone https://github.com/YamiKnigth/panel-installer.git
cd panel-installer
sudo bash install.sh
```

## Flujo recomendado

### Instalar el panel

La opción de instalación del panel hace esto:

- Muestra todas las IPs IPv4 globales detectadas en la instancia.
- Instala Nginx, MariaDB, Redis, Composer y PHP 8.2 o 8.3 desde los repositorios nativos de Ubuntu 24.04.
- Descarga la última release del panel.
- Configura la base de datos local del panel.
- Genera el usuario admin inicial.
- Configura Nginx para HTTP o HTTPS.
- Guarda credenciales en /root/credenciales_pterodactyl.txt.

### Instalar Wings local o remoto

La opción de instalación de Wings permite:

- Reutilizar el panel local si existe en la misma instancia (cifra los tokens invocando la app Laravel real del panel para garantizar compatibilidad byte a byte).
- O registrar un nodo remoto pidiendo la URL del panel, el `APP_KEY` y credenciales de MariaDB (cifra los tokens con una reimplementación manual del formato de `Illuminate\Encryption\Encrypter`).
- Instalar Docker si no existe, y descargar la imagen `ghcr.io/pterodactyl/installers:alpine` necesaria para instalar servidores.
- Detectar arquitectura (amd64/arm64) al descargar el binario de Wings.
- Insertar el nodo y la allocation directamente en MariaDB, verificando por round-trip que el token cifrado y lo que MySQL realmente guardó coinciden byte a byte; si algo no cuadra, revierte la inserción antes de tocar `config.yml` o `systemd`.
- Generar `/etc/pterodactyl/config.yml`.
- Abrir puertos en `ufw` (si está activo) para la API de Wings, SFTP y la allocation.
- Crear, habilitar y **verificar** que el servicio systemd de Wings quedó activo (si no, muestra `journalctl -u wings` y aborta).

Importante para Wings remoto:

- El nodo debe poder conectarse por red a MariaDB del panel.
- Necesitas un usuario con permisos sobre la base de datos del panel.
- Debes indicar la URL pública real del panel y su `APP_KEY` completo (está en `/var/www/pterodactyl/.env`).

Si el nodo se configura con esquema `https`, Wings necesita su propio certificado SSL válido para su FQDN — el instalador no lo genera automáticamente, solo lo advierte.

### Actualizar Panel y Wings

Ambas opciones primero comparan la versión instalada contra la última release de GitHub (`config/app.php` del panel, `wings --version` para Wings) y **no hacen nada** si ya estás en la última versión — ni backup, ni descarga.

Si hay una versión nueva, generan un respaldo previo en `/tmp` y preguntan de forma interactiva si quieres subirlo a un host público antes de continuar. Si la subida falla o se omite, la actualización sigue igual con el archivo local ya generado.

`update_wings.sh` detecta arquitectura (amd64/arm64) igual que la instalación, verifica el binario nuevo (`--version`) antes de detener el servicio actual, y confirma que Wings quedó activo después de reemplazarlo.

### Crear respaldos manuales

La opción de respaldo ofrece tres modos:

1. Solo Panel (BD + `.env`).
2. Panel + Wings (agrega `config.yml`).
3. Solo Wings (`config.yml` únicamente, requiere que Wings ya esté instalado).

El zip resultante queda siempre en `/tmp`, e incluye además `runtime.conf` (metadatos del instalador) y un `RESTORE.txt` con el detalle del contenido. Subirlo a bashupload.com es opcional y se confirma de forma interactiva — es un host público sin autenticación, y el archivo contiene credenciales.

### Restaurar respaldos

Al entrar, la restauración lista los respaldos ya generados en `/tmp` (más reciente primero, con tamaño y fecha) para elegir uno por número, o entrar manualmente otra ruta local / URL.

La restauración repone, según lo que contenga el zip:

- La base de datos del panel y su `.env`.
- La configuración de Wings — pero antes de reiniciar el servicio, valida que el UUID del nodo restaurado siga existiendo en la base de datos actual del panel; si no coincide, deja el `config.yml` copiado pero no reinicia Wings y avisa que hay que registrar el nodo de nuevo.
- Los metadatos locales del instalador (`runtime.conf`).

Nota importante: el respaldo no contiene el código fuente completo del panel ni el binario de Wings. La restauración está pensada para un servidor donde ya se reinstaló primero el software base y luego se reinyectan base de datos y configuraciones.

## Estructura del repositorio

```text
panel-installer/
├── install.sh
├── installer.sh
├── README.md
├── requeriments.md
└── scripts/
	├── backup.sh
	├── common.sh
	├── install_panel.sh
	├── install_wings.sh
	├── restore_backup.sh
	├── update_panel.sh
	└── update_wings.sh
```

## Limitaciones actuales

- La instalación de Wings remoto depende de conectividad MariaDB directa hacia la base de datos del panel.
- No configura DNS externo ni genera certificados SSL automáticamente (ni para el panel en el flujo de Wings, ni para Wings mismo si usas esquema `https`); esos pasos siguen siendo responsabilidad del administrador.
- Las reglas de `ufw` solo se agregan si `ufw` ya está activo en la instancia; con otros firewalls (iptables/nftables directos, firewall del proveedor cloud) hay que abrir los puertos manualmente.
- La subida de respaldos usa bashupload.com, un host público sin autenticación — no hay otro backend de subida configurable todavía.

## Archivo de especificaciones

Las decisiones de esta implementación se alinean con lo descrito en [requeriments.md](requeriments.md), ampliando además el flujo para cubrir actualización y restauración.
