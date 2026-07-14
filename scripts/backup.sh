#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}=== MENÚ DE RESPALDOS ===${NC}"
echo "1) Respaldar Solo Panel"
echo "2) Respaldar Panel + Wings (Sin volúmenes de juegos)"
read -p "Selecciona una opción [1-2]: " opcion_backup

FECHA=$(date +%F_%H-%M-%S)
RUTA_ZIP="/tmp/pterodactyl_backup_$FECHA.zip"
DIR_TEMP="/tmp/pterodactyl_backup_datos"
mkdir -p "$DIR_TEMP"

if [ "$opcion_backup" == "1" ] || [ "$opcion_backup" == "2" ]; then
    echo -e "${AZUL}[*] Exportando Base de Datos...${NC}"
    # Activar comando real: mysqldump -u root pterodactyl > "$DIR_TEMP/db.sql"
    touch "$DIR_TEMP/db.sql" # Placeholder

    echo -e "${AZUL}[*] Copiando variables de entorno...${NC}"
    # Activar comando real: cp /var/www/pterodactyl/.env "$DIR_TEMP/"
    touch "$DIR_TEMP/.env" # Placeholder
    
    if [ "$opcion_backup" == "2" ]; then
        echo -e "${AZUL}[*] Copiando configuración de Wings...${NC}"
        # Activar comando real: cp /etc/pterodactyl/config.yml "$DIR_TEMP/"
        touch "$DIR_TEMP/config.yml" # Placeholder
    fi
    
    echo -e "${AZUL}[*] Comprimiendo...${NC}"
    zip -r "$RUTA_ZIP" "$DIR_TEMP" > /dev/null
    
    echo -e "${AZUL}[*] Subiendo a bashupload.com (Servidor temporal)...${NC}"
    ENLACE=$(curl -s --upload-file "$RUTA_ZIP" "https://bashupload.com/backup_$FECHA.zip")
    
    clear
    echo -e "${VERDE}==================================================${NC}"
    echo -e "${VERDE}               RESPALDO COMPLETADO                ${NC}"
    echo -e "${VERDE}==================================================${NC}"
    echo -e "Descárgalo en otra máquina con el siguiente enlace:"
    echo -e "${AZUL}$ENLACE${NC}"
    echo -e "Nota: El enlace expirará automáticamente en 3 días."
    echo -e "${VERDE}==================================================${NC}"
    
    rm -rf "$DIR_TEMP"
else
    echo -e "${ROJO}Opción inválida.${NC}"
fi
