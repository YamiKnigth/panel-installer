#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}=== MENÚ DE RESPALDOS PTERODACTYL ===${NC}"
echo "1) Respaldar Solo Panel (Base de Datos + .env)"
echo "2) Respaldar Panel + Wings (Sin archivos/volúmenes de juegos)"
read -p "Selecciona una opción [1-2]: " opcion_backup

FECHA=$(date +%F_%H-%M-%S)
RUTA_ZIP="/tmp/pterodactyl_backup_$FECHA.zip"
DIR_TEMP="/tmp/pterodactyl_backup_datos"
mkdir -p "$DIR_TEMP"

if [ "$opcion_backup" == "1" ] || [ "$opcion_backup" == "2" ]; then
    
    echo -e "${AZUL}[*] Exportando Base de Datos (panel)...${NC}"
    # Ejecutamos el volcado de la DB sin pedir contraseña porque estamos en local/root
    mysqldump -u root panel > "$DIR_TEMP/db_panel_backup.sql"

    echo -e "${AZUL}[*] Copiando archivo de variables críticas (.env)...${NC}"
    cp /var/www/pterodactyl/.env "$DIR_TEMP/env_panel.txt"
    
    if [ "$opcion_backup" == "2" ]; then
        echo -e "${AZUL}[*] Copiando configuración del Nodo (Wings)...${NC}"
        if [ -f "/etc/pterodactyl/config.yml" ]; then
            cp /etc/pterodactyl/config.yml "$DIR_TEMP/config_wings.yml"
        else
            echo -e "${ROJO}[!] No se encontró config.yml. Omitiendo Wings.${NC}"
        fi
    fi
    
    echo -e "${AZUL}[*] Comprimiendo archivos de respaldo...${NC}"
    cd "$DIR_TEMP" || exit
    zip -r "$RUTA_ZIP" . > /dev/null
    cd - || exit
    
    echo -e "${AZUL}[*] Subiendo a bashupload.com para generar enlace temporal...${NC}"
    ENLACE=$(curl -s --upload-file "$RUTA_ZIP" "https://bashupload.com/backup_$FECHA.zip")
    
    clear
    echo -e "${VERDE}==================================================${NC}"
    echo -e "${VERDE}               RESPALDO COMPLETADO                ${NC}"
    echo -e "${VERDE}==================================================${NC}"
    echo -e "Descárgalo en tu computadora o en otro servidor usando este comando:"
    echo -e "${AZUL}wget $ENLACE${NC}"
    echo -e ""
    echo -e "Nota: El enlace expirará automáticamente en 3 días o tras ser descargado."
    echo -e "${VERDE}==================================================${NC}"
    
    rm -rf "$DIR_TEMP"
else
    echo -e "${ROJO}Opción inválida.${NC}"
fi
