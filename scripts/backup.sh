#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}=== MODULO DE RESPALDOS REALES ===${NC}"
echo "1) Respaldar Solo Panel (Base de Datos + .env)"
echo "2) Respaldar Panel + Configuración de Wings"
read -p "Selecciona la operación [1-2]: " opcion_backup

if [[ "$opcion_backup" != "1" && "$opcion_backup" != "2" ]]; then
    echo -e "${ROJO}[!] Opción inválida.${NC}"
    exit 1
fi

FECHA=$(date +%F_%H-%M-%S)
RUTA_ZIP="/tmp/pterodactyl_backup_$FECHA.zip"
DIR_TEMP="/tmp/pterodactyl_backup_datos"
mkdir -p "$DIR_TEMP"

# 1. Volcado real de base de datos
echo -e "${AZUL}[*] Extrayendo base de datos MySQL (panel)...${NC}"
if ! mysqldump -u root panel > "$DIR_TEMP/db_panel_backup.sql" 2>/dev/null; then
    echo -e "${ROJO}[!] Error al exportar la base de datos. Verifica que el panel esté instalado.${NC}"
    rm -rf "$DIR_TEMP"
    exit 1
fi

# 2. Copia real del archivo de entorno
echo -e "${AZUL}[*] Copiando archivo de configuración .env del panel...${NC}"
if [ -f "/var/www/pterodactyl/.env" ]; then
    cp /var/www/pterodactyl/.env "$DIR_TEMP/env_panel.txt"
else
    echo -e "${ROJO}[!] No se localizó el archivo .env principal.${NC}"
fi

# 3. Copia real de Wings si se solicita
if [ "$opcion_backup" == "2" ]; then
    echo -e "${AZUL}[*] Extrayendo configuraciones de Wings...${NC}"
    if [ -f "/etc/pterodactyl/config.yml" ]; then
        cp /etc/pterodactyl/config.yml "$DIR_TEMP/config_wings.yml"
    else
        echo -e "${ROJO}[!] Archivo config.yml de Wings no detectado. Omitiendo...${NC}"
    fi
fi

# 4. Compresión real
echo -e "${AZUL}[*] Generando empaquetado comprimido .zip...${NC}"
apt install -y zip > /dev/null
cd "$DIR_TEMP" || exit
zip -r "$RUTA_ZIP" . > /dev/null
cd - || exit

# 5. Envío al servidor temporal externo
echo -e "${AZUL}[*] Subiendo archivo a la nube temporal (bashupload.com)...${NC}"
ENLACE=$(curl -s --upload-file "$RUTA_ZIP" "https://bashupload.com/backup_$FECHA.zip")

clear
echo -e "${VERDE}==================================================${NC}"
echo -e "${VERDE}            RESPALDO GENERADO CON ÉXITO           ${NC}"
echo -e "${VERDE}==================================================${NC}"
echo -e "Enlace de descarga directa válido por 3 días:"
echo -e "${AZUL}$ENLACE${NC}"
echo -e "Comando rápido para restaurar en otro servidor:"
echo -e "wget $ENLACE"
echo -e "${VERDE}==================================================${NC}"

rm -rf "$DIR_TEMP"
