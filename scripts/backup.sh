#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

include_wings="no"
wings_only="no"

echo -e "${AZUL}=== MODULO DE RESPALDOS ===${NC}"
echo "1) Respaldar solo Panel (BD + .env)"
echo "2) Respaldar Panel + Wings"
echo "3) Respaldar solo Wings (config.yml)"
read -r -p "Selecciona la operación [1-3]: " opcion_backup

case "$opcion_backup" in
  1) include_wings="no" ;;
  2) include_wings="yes" ;;
  3) include_wings="yes"; wings_only="yes" ;;
  *)
    log_error "Opción inválida."
    exit 1
    ;;
esac

if [ "$wings_only" = "yes" ] && [ ! -f "$WINGS_CONFIG" ]; then
  log_error "No se encontró $WINGS_CONFIG. No hay nada que respaldar de Wings."
  exit 1
fi

if [ "$wings_only" = "yes" ]; then
  backup_zip=$(create_wings_only_backup_archive "manual")
else
  backup_zip=$(create_backup_archive "$include_wings" "manual")
fi
log_success "Respaldo local creado en: $backup_zip"

echo -e "${VERDE}==================================================${NC}"
echo -e "${VERDE}            RESPALDO GENERADO CON ÉXITO           ${NC}"
echo -e "${VERDE}==================================================${NC}"
echo "Archivo local: $backup_zip"

if confirm_action "¿Subir este respaldo a bashupload.com? (host público, sin autenticación — el archivo contiene credenciales)"; then
  upload_output=$(upload_backup_archive "$backup_zip")
  download_url=$(printf '%s\n' "$upload_output" | head -n 1)

  if [[ "$download_url" =~ ^https?:// ]]; then
    echo "Enlace de descarga: $download_url"
    echo "Restauración remota rápida: wget -O /tmp/$(basename "$backup_zip") '$download_url'"
  else
    echo "Respuesta de la subida:"
    printf '%s\n' "$upload_output"
  fi
else
  log_info "Subida omitida. El respaldo permanece únicamente en: $backup_zip"
fi

echo "Para restaurar desde este instalador usa la opción de menú: Restaurar respaldo."
echo -e "${VERDE}==================================================${NC}"
