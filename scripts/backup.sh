#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

include_wings="no"

echo -e "${AZUL}=== MODULO DE RESPALDOS ===${NC}"
echo "1) Respaldar solo Panel (BD + .env)"
echo "2) Respaldar Panel + Wings"
read -r -p "Selecciona la operación [1-2]: " opcion_backup

case "$opcion_backup" in
  1) include_wings="no" ;;
  2) include_wings="yes" ;;
  *)
    log_error "Opción inválida."
    exit 1
    ;;
esac

backup_zip=$(create_backup_archive "$include_wings" "manual")
log_success "Respaldo local creado en: $backup_zip"

upload_output=$(upload_backup_archive "$backup_zip")
download_url=$(printf '%s\n' "$upload_output" | head -n 1)

echo -e "${VERDE}==================================================${NC}"
echo -e "${VERDE}            RESPALDO GENERADO CON ÉXITO           ${NC}"
echo -e "${VERDE}==================================================${NC}"
echo "Archivo local: $backup_zip"
if [[ "$download_url" =~ ^https?:// ]]; then
  echo "Enlace de descarga: $download_url"
  echo "Restauración remota rápida: wget -O /tmp/$(basename "$backup_zip") '$download_url'"
else
  echo "Respuesta de la subida:"
  printf '%s\n' "$upload_output"
fi
echo "Para restaurar desde este instalador usa la opción de menú: Restaurar respaldo."
echo -e "${VERDE}==================================================${NC}"
