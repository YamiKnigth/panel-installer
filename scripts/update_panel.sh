#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

if ! panel_installed; then
  log_error "No se encontró una instalación del panel en $PANEL_DIR."
  exit 1
fi

pre_backup=$(create_backup_archive "yes" "pre_update_panel")
log_success "Respaldo previo generado: $pre_backup"

if upload_output=$(upload_backup_archive "$pre_backup"); then
  upload_url=$(printf '%s\n' "$upload_output" | head -n 1)
  if [[ "$upload_url" =~ ^https?:// ]]; then
    log_success "Respaldo remoto disponible en: $upload_url"
  fi
else
  log_warn "La subida automática del respaldo falló. El archivo local permanece en: $pre_backup"
fi

cd "$PANEL_DIR"
php artisan down || true

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"; php artisan up >/dev/null 2>&1 || true' EXIT

log_info "Descargando la última versión del panel..."
curl -fsSL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o "$tmp_dir/panel.tar.gz"
tar -xzf "$tmp_dir/panel.tar.gz" -C "$tmp_dir"

find "$PANEL_DIR" -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'storage' ! -name 'bootstrap' -exec rm -rf {} +
cp -a "$tmp_dir"/. "$PANEL_DIR"/

composer install --no-dev --optimize-autoloader
php artisan view:clear
php artisan config:clear
php artisan migrate --seed --force
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
php artisan queue:restart || true
php artisan up || true

systemctl restart php8.3-fpm nginx pteroq.service
trap - EXIT
rm -rf "$tmp_dir"

log_success "Panel actualizado correctamente."