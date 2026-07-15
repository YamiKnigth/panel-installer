# Pterodactyl Installer para Multipass

Herramienta en Bash para instalar, actualizar, respaldar y restaurar despliegues de Pterodactyl sobre Ubuntu 24.04 dentro de instancias Multipass. Está orientada a dos escenarios:

- Panel local y Wings local en la misma instancia.
- Panel local en una instancia y Wings remoto en otra instancia distinta.

La automatización está pensada específicamente para Ubuntu 24.04 nativo, evitando PPAs externos para PHP, MariaDB o Redis.

## Qué hace la herramienta

El menú principal expone estas operaciones:

1. Instalar Panel Pterodactyl.
2. Instalar Pterodactyl Wings.
3. Crear respaldo y subirlo a bashupload.com.
4. Actualizar Panel Pterodactyl con respaldo previo.
5. Actualizar Pterodactyl Wings con respaldo previo.
6. Restaurar un respaldo generado por esta herramienta.
7. Salir.

Además:

- Detecta varias IPs de la instancia y te deja elegir la correcta, algo clave en Multipass sobre macOS y Windows.
- Instala PHP 8.3, MariaDB, Redis y Nginx desde los repositorios oficiales de Ubuntu 24.04.
- Genera credenciales aleatorias para el panel y la base de datos.
- Registra Wings directamente en la base de datos del panel para evitar fallos por proxy o 404 al usar la API web.
- Genera respaldos reales con mysqldump, .env y config.yml de Wings.
- Permite restaurar esos respaldos desde una URL o desde un archivo zip local.

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
- Instala Nginx, MariaDB, Redis, Composer y PHP desde los repositorios nativos, priorizando PHP 8.3 cuando está disponible.
- Descarga la última release del panel.
- Configura la base de datos local del panel.
- Genera el usuario admin inicial.
- Configura Nginx para HTTP o HTTPS.
- Guarda credenciales en /root/credenciales_pterodactyl.txt.

### Instalar Wings local o remoto

La opción de instalación de Wings permite:

- Reutilizar el panel local si existe en la misma instancia.
- O registrar un nodo remoto pidiendo la URL del panel y credenciales de MariaDB.
- Instalar Docker si no existe.
- Insertar el nodo y la allocation directamente en MariaDB.
- Generar /etc/pterodactyl/config.yml.
- Crear y habilitar el servicio systemd de Wings.

Importante para Wings remoto:

- El nodo debe poder conectarse por red a MariaDB del panel.
- Necesitas un usuario con permisos sobre la base de datos del panel.
- Debes indicar la URL pública real del panel.

### Actualizar Panel y Wings

Las opciones de actualización siempre generan un respaldo previo. Ese respaldo:

- Se guarda primero en /tmp.
- Luego intenta subirse a bashupload.com.

Si la subida falla, la actualización puede continuar con el archivo local ya generado.

### Crear respaldos manuales

La opción de respaldo crea un zip con:

- panel.sql
- panel.env
- wings.config.yml cuando existe
- runtime.conf con metadatos locales del instalador

El zip se sube a bashupload.com y también queda guardado localmente en /tmp.

### Restaurar respaldos

La restauración acepta:

- Una URL de bashupload.com.
- O una ruta local a un zip.

La restauración repone:

- La base de datos del panel, si el respaldo la contiene.
- El archivo .env del panel.
- La configuración de Wings.
- Los metadatos locales del instalador.

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
- El instalador asume arquitectura amd64 para descargar Wings.
- No configura automáticamente reglas de firewall o DNS externos; esos pasos siguen siendo responsabilidad del administrador.

## Archivo de especificaciones

Las decisiones de esta implementación se alinean con lo descrito en [requeriments.md](requeriments.md), ampliando además el flujo para cubrir actualización y restauración.
