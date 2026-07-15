# Especificaciones Técnicas y Arquitectura: Herramienta Automatizada Pterodactyl Installer

Este documento detalla el estado actual, la estructura y los requerimientos operativos de la herramienta de instalación automatizada para el Panel Pterodactyl y Wings, optimizada para entornos **Ubuntu 24.04 LTS (Nativo)** corriendo sobre instancias virtuales de **Multipass** (en arquitecturas Windows Hyper-V y macOS QEMU/vmnet).

---

## 1. Estructura Actual del Repositorio
El repositorio debe estructurarse bajo la siguiente jerarquía limpia y modular:

```text
panel-installer/
├── install.sh                # Script/Menú principal interactivo
└── scripts/
    ├── install_panel.sh      # Script de instalación nativa del Panel
    ├── install_wings.sh      # Script de instalación y autoconfiguración de Wings
    └── backup.sh             # Módulo funcional de respaldos automáticos
2. Lo que la Herramienta DEBE HACER (Flujo Completo)
A. Menú Principal (install.sh)
Presentar un menú interactivo visual en consola con las siguientes opciones:

1) Instalar Panel Pterodactyl

2) Instalar Pterodactyl Wings (Nodo)

3) Crear Respaldo Completo (Panel + DB)

4) Salir

Permanencia de Logs: Ninguna opción debe limpiar la pantalla de forma agresiva (clear) si ocurre un fallo, permitiendo al administrador hacer scroll para diagnosticar errores.

B. Instalación del Panel (scripts/install_panel.sh)
Detección Multi-Interfaz de IP (Crítico para macOS/Multipass): El script no debe asumir la primera IP del sistema (hostname -I | awk '{print $1}'), ya que en entornos puenteados (Bridge) esto captura la red interna aislada (192.168.252.X). Debe listar de forma numerada e interactiva todas las IPs de la máquina para que el usuario elija explícitamente la IP local real asignada por el módem.

Instalación 100% Nativa (Ubuntu 24.04): No añadir repositorios PPA externos de terceros (como ppa:ondrej/php o instaladores manuales de MariaDB) debido a conflictos de firmas e incompatibilidades. Debe instalar PHP 8.3, MariaDB y Redis directamente desde los repositorios oficiales y nativos de Ubuntu.

Paquetes Desglosados: Instalar las dependencias de PHP declarando paquete por paquete de forma explícita (php8.3-fpm, php8.3-cli, etc.), evitando el uso de llaves de expansión (php8.3-{cli,fpm}), ya que ciertos entornos de ejecución curl las ignoran y omiten componentes críticos como el motor FPM.

Automatización No Interactiva: Inyectar export DEBIAN_FRONTEND=noninteractive para evitar bloqueos por ventanas emergentes del sistema operativo.

Configuración Interna: Generar credenciales seguras aleatorias para la base de datos y la cuenta de administrador inicial. Configurar las directivas de Nginx y el archivo .env del panel con la IP real elegida por el usuario.

C. Instalación de Wings (scripts/install_wings.sh)
Instalación de Entorno Docker: Validar si Docker existe en el sistema; si no, desplegarlo utilizando el script oficial estable (https://get.docker.com/).

Auto-Configuración Directa en Base de Datos (Evitar Error 404): Los scripts automatizados no deben consumir la API HTTP web del panel local para dar de alta el nodo, ya que las restricciones de proxy de Nginx en despliegues paralelos devuelven códigos 404 Not Found. En su lugar, el script debe inyectar el nuevo nodo directamente en la base de datos MariaDB (panel.nodes y panel.allocations) generando un UUID y tokens aleatorios.

Escritura Nativa de Archivo: Generar de forma directa el archivo /etc/pterodactyl/config.yml mapeando los tokens inyectados en la base de datos.

Persistencia del Demonio: Crear y habilitar el servicio de Systemd (wings.service) para garantizar que el nodo corra en segundo plano y encienda junto al sistema.

D. Sistema de Respaldos (scripts/backup.sh)
Operación Real (Sin simulaciones): Ejecutar un volcado real de la base de datos del panel utilizando mysqldump.

Empaquetamiento: Recopilar el volcado .sql, el archivo de entorno .env del panel y (si se selecciona) el archivo config.yml de Wings en un archivo comprimido .zip único en el directorio /tmp.

Exportación Temporal: Subir el archivo empaquetado a una nube de almacenamiento temporal de texto plano (bashupload.com) y devolverle al usuario el enlace de descarga directo junto con las instrucciones de restauración en consola.