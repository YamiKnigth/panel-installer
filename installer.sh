#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${ROJO}[!] Por favor, ejecuta este script como root (sudo).${NC}"
  exit 1
fi

# Ruta base de tu repositorio
REPO_BASE="https://raw.githubusercontent.com/YamiKnigth/panel-installer/main"
mkdir -p /tmp/pterodactyl-installer

ejecutar_modulo() {
    local script_name=$1
    echo -e "${AZUL}[*] Descargando y ejecutando módulo $script_name...${NC}"
    curl -sSL "$REPO_BASE/scripts/$script_name" -o "/tmp/pterodactyl-installer/$script_name"
    chmod +x "/tmp/pterodactyl-installer/$script_name"
    bash "/tmp/pterodactyl-installer/$script_name"
}

while true; do
    clear
    echo -e "${AZUL}==================================================${NC}"
    echo -e "${AZUL}     HERRAMIENTA DE AUTOMATIZACIÓN PTERODACTYL    ${NC}"
    echo -e "${AZUL}==================================================${NC}"
    echo "1) Instalar Panel Pterodactyl"
    echo "2) Instalar Wings (Local o Remoto)"
    echo "3) Crear y Subir Respaldo"
    echo "4) Salir"
    echo -e "${AZUL}==================================================${NC}"
    read -p "Selecciona una opción [1-4]: " opcion

    case $opcion in
        1) ejecutar_modulo "install_panel.sh" ;;
        2) ejecutar_modulo "install_wings.sh" ;;
        3) ejecutar_modulo "backup.sh" ;;
        4) echo -e "${VERDE}¡Limpiando archivos temporales y saliendo!${NC}"; rm -rf /tmp/pterodactyl-installer; exit 0 ;;
        *) echo -e "${ROJO}[!] Opción no válida.${NC}"; sleep 2 ;;
    esac
    echo ""
    read -p "Presiona Enter para volver al menú principal..."
done
