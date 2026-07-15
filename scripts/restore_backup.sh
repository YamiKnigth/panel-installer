#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive
ensure_packages unzip curl mariadb-client

backup_source=$(prompt_required "Ruta local o URL del respaldo .zip: ")
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

unzip -oq "$archive_path" -d "$work_dir/extracted"

restore_panel="no"
restore_wings="no"

if [ -f "$work_dir/extracted/panel.sql" ] || [ -f "$work_dir/extracted/panel.env" ]; then
  restore_panel="yes"
fi

if [ -f "$work_dir/extracted/wings.config.yml" ]; then
  restore_wings="yes"
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

  systemctl restart nginx php8.3-fpm pteroq.service 2>/dev/null || true
fi

if [ "$restore_wings" = "yes" ]; then
  mkdir -p /etc/pterodactyl
  cp "$work_dir/extracted/wings.config.yml" "$WINGS_CONFIG"
  systemctl restart wings.service 2>/dev/null || true
fi

if [ -f "$work_dir/extracted/runtime.conf" ]; then
  mkdir -p "$RUNTIME_DIR"
  cp "$work_dir/extracted/runtime.conf" "$RUNTIME_FILE"
fi

log_success "Restauración finalizada."