#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive
ensure_packages unzip curl mariadb-client

php_fpm_service=$(php_fpm_service_name)

mapfile -t local_backups < <(ls -1t /tmp/pterodactyl_backup_*.zip 2>/dev/null || true)

backup_source=""
if [ "${#local_backups[@]}" -gt 0 ]; then
  echo -e "${AZUL}Respaldos locales encontrados en /tmp:${NC}"
  idx=0
  for backup_file in "${local_backups[@]}"; do
    idx=$((idx + 1))
    echo "  $idx) $backup_file ($(du -h "$backup_file" | cut -f1), $(date -r "$backup_file" '+%Y-%m-%d %H:%M:%S'))"
  done
  echo "  0) Ingresar otra ruta local o URL manualmente"

  while true; do
    read -r -p "Selecciona un respaldo [0-$idx]: " backup_choice
    if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 0 ] && [ "$backup_choice" -le "$idx" ]; then
      break
    fi
    log_warn "Selecciona un número válido (0-$idx)."
  done

  if [ "$backup_choice" != "0" ]; then
    backup_source="${local_backups[$((backup_choice - 1))]}"
  fi
fi

if [ -z "$backup_source" ]; then
  backup_source=$(prompt_required "Ruta local o URL del respaldo .zip: ")
fi
work_dir=$(mktemp -d)
archive_path="$work_dir/backup.zip"
trap 'rm -rf "$work_dir"' EXIT

if [[ "$backup_source" =~ ^https?:// ]]; then
  log_info "Descargando respaldo remoto..."
  curl -fsSL "$backup_source" -o "$archive_path"
else
  if [ ! -f "$backup_source" ]; then
    log_error "No existe el archivo indicado: $backup_source"
    exit 1
  fi
  cp "$backup_source" "$archive_path"
fi

if ! unzip -tq "$archive_path" >/dev/null 2>&1; then
  log_error "El archivo de respaldo no pasó la verificación de integridad (zip corrupto o incompleto)."
  exit 1
fi

echo -e "${AZUL}Contenido del respaldo:${NC}"
unzip -l "$archive_path"

unzip -oq "$archive_path" -d "$work_dir/extracted"

restore_panel="no"
restore_wings="no"

if [ -f "$work_dir/extracted/panel.sql" ] || [ -f "$work_dir/extracted/panel.env" ]; then
  restore_panel="yes"
fi

if [ -f "$work_dir/extracted/wings.config.yml" ]; then
  restore_wings="yes"
fi

echo
log_warn "Esta operación sobrescribirá lo siguiente si está presente en el respaldo:"
[ -f "$work_dir/extracted/panel.env" ] && echo "  - $PANEL_DIR/.env"
[ -f "$work_dir/extracted/panel.sql" ] && echo "  - La base de datos actual del panel (se reemplaza por completo)"
[ -f "$work_dir/extracted/wings.config.yml" ] && echo "  - $WINGS_CONFIG"
[ -f "$work_dir/extracted/runtime.conf" ] && echo "  - $RUNTIME_FILE"

if ! confirm_action "¿Continuar con la restauración?"; then
  log_info "Restauración cancelada por el usuario."
  exit 0
fi

if [ "$restore_panel" = "yes" ]; then
  if ! panel_installed; then
    log_warn "No existe una instalación del panel. La restauración de BD/.env asume que el panel ya fue instalado previamente."
  fi

  if [ -f "$work_dir/extracted/panel.env" ]; then
    mkdir -p "$PANEL_DIR"
    cp "$work_dir/extracted/panel.env" "$PANEL_DIR/.env"
  fi

  load_panel_db_credentials

  if [ -f "$PANEL_DIR/artisan" ]; then
    cd "$PANEL_DIR"
    php artisan down || true
  fi

  if [ -f "$work_dir/extracted/panel.sql" ]; then
    log_info "Restaurando base de datos del panel..."
    if [ -n "$PANEL_DB_PASSWORD" ]; then
      MYSQL_PWD="$PANEL_DB_PASSWORD" mysql -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" < "$work_dir/extracted/panel.sql"
    else
      mysql -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" < "$work_dir/extracted/panel.sql"
    fi
  fi

  if [ -f "$PANEL_DIR/artisan" ]; then
    cd "$PANEL_DIR"
    php artisan up || true
    php artisan optimize:clear || true
  fi

  systemctl restart nginx "$php_fpm_service" pteroq.service 2>/dev/null || true
fi

if [ "$restore_wings" = "yes" ]; then
  restored_uuid=$(sed -n 's/^uuid:[[:space:]]*//p' "$work_dir/extracted/wings.config.yml" | head -n 1 | tr -d "\"'")

  node_match=""
  if [ -n "$restored_uuid" ] && panel_installed; then
    load_panel_db_credentials
    if panel_db_reachable "$PANEL_DB_HOST" "$PANEL_DB_PORT" "$PANEL_DB_NAME" "$PANEL_DB_USER" "$PANEL_DB_PASSWORD" 2>/dev/null; then
      node_match=$(run_panel_mysql_single "SELECT id FROM nodes WHERE uuid = '$(sql_escape "$restored_uuid")' LIMIT 1;" 2>/dev/null || true)
    fi
  fi

  mkdir -p /etc/pterodactyl
  cp "$work_dir/extracted/wings.config.yml" "$WINGS_CONFIG"
  chmod 600 "$WINGS_CONFIG"

  if [ -n "$restored_uuid" ] && [ -z "$node_match" ]; then
    log_warn "El UUID del nodo restaurado ($restored_uuid) no existe en la base de datos actual del panel."
    log_warn "Wings no se iniciará con esta configuración: el panel no reconocerá el token. Vuelve a ejecutar install_wings.sh para registrar un nodo nuevo."
  else
    systemctl restart wings.service 2>/dev/null || true
  fi
fi

if [ -f "$work_dir/extracted/runtime.conf" ]; then
  mkdir -p "$RUNTIME_DIR"
  cp "$work_dir/extracted/runtime.conf" "$RUNTIME_FILE"
fi

log_success "Restauración finalizada."