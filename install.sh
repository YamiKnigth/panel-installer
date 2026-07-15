#!/bin/bash

set -Eeuo pipefail

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${ROJO}[!] Ejecuta este script como root o con sudo.${NC}"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_BASE="https://raw.githubusercontent.com/YamiKnigth/panel-installer/main"
TMP_BASE="/tmp/pterodactyl-installer"

mostrar_encabezado() {
  echo
  echo -e "${AZUL}==================================================${NC}"
  echo -e "${AZUL}        PTERODACTYL INSTALLER PARA MULTIPASS      ${NC}"
  echo -e "${AZUL}==================================================${NC}"
}

preparar_modulo_remoto() {
  local script_name="$1"

  mkdir -p "$TMP_BASE/scripts"
  curl -fsSL "$REPO_BASE/scripts/common.sh" -o "$TMP_BASE/scripts/common.sh"
  curl -fsSL "$REPO_BASE/scripts/$script_name" -o "$TMP_BASE/scripts/$script_name"
  chmod +x "$TMP_BASE/scripts/common.sh" "$TMP_BASE/scripts/$script_name"
}

ejecutar_modulo() {
  local script_name="$1"

  if [ -f "$SCRIPT_DIR/scripts/$script_name" ] && [ -f "$SCRIPT_DIR/scripts/common.sh" ]; then
    echo -e "${AZUL}[*] Ejecutando módulo local: $script_name${NC}"
    bash "$SCRIPT_DIR/scripts/$script_name"
    return
  fi

  echo -e "${AZUL}[*] Descargando módulo remoto: $script_name${NC}"
  preparar_modulo_remoto "$script_name"
  bash "$TMP_BASE/scripts/$script_name"
}

while true; do
  mostrar_encabezado
  echo "1) Instalar Panel Pterodactyl"
  echo "2) Instalar Pterodactyl Wings"
  echo "3) Crear respaldo y subirlo"
  echo "4) Actualizar Panel Pterodactyl"
  echo "5) Actualizar Pterodactyl Wings"
  echo "6) Restaurar respaldo"
  echo "7) Salir"
  echo -e "${AZUL}==================================================${NC}"
  read -r -p "Selecciona una opción [1-7]: " opcion

  case "$opcion" in
    1) ejecutar_modulo "install_panel.sh" ;;
    2) ejecutar_modulo "install_wings.sh" ;;
    3) ejecutar_modulo "backup.sh" ;;
    4) ejecutar_modulo "update_panel.sh" ;;
    5) ejecutar_modulo "update_wings.sh" ;;
    6) ejecutar_modulo "restore_backup.sh" ;;
    7)
      echo -e "${VERDE}[*] Cerrando herramienta.${NC}"
      rm -rf "$TMP_BASE"
      exit 0
      ;;
    *)
      echo -e "${AMARILLO}[!] Opción no válida.${NC}"
      ;;
  esac

  echo
  read -r -p "Presiona Enter para volver al menú principal..." _
done