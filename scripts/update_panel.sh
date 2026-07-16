#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

php_fpm_service=$(php_fpm_service_name)

if ! panel_installed; then
  log_error "No se encontró una instalación del panel en $PANEL_DIR."
  exit 1
fi

pre_backup=$(create_backup_archive "yes" "pre_update_panel")
log_success "Respaldo previo generado: $pre_backup"

if confirm_action "¿Subir el respaldo previo a bashupload.com? (host público, sin autenticación)"; then
  if upload_output=$(upload_backup_archive "$pre_backup"); then
    upload_url=$(printf '%s\n' "$upload_output" | head -n 1)
    if [[ "$upload_url" =~ ^https?:// ]]; then
      log_success "Respaldo remoto disponible en: $upload_url"
    fi
  else
    log_warn "La subida automática del respaldo falló. El archivo local permanece en: $pre_backup"
  fi
fi

latest_tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/pterodactyl/panel/releases/latest | sed 's#.*/tag/##')
log_info "Última versión disponible del panel: ${latest_tag:-desconocida}."
if ! confirm_action "¿Continuar con la actualización a esta versión?"; then
  log_info "Actualización cancelada por el usuario."
  exit 0
fi

required_mb=1024
available_mb=$(df -Pm "$PANEL_DIR" | awk 'NR==2 {print $4}')
if [ -z "$available_mb" ] || [ "$available_mb" -lt "$required_mb" ]; then
  log_error "Espacio en disco insuficiente en $PANEL_DIR (disponible: ${available_mb:-0}MB, requerido: ${required_mb}MB). Aborta antes de tocar el panel."
  exit 1
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

COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan view:clear
php artisan config:clear
php artisan migrate --seed --force
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
php artisan queue:restart || true
php artisan up || true

systemctl restart "$php_fpm_service" nginx pteroq.service
trap - EXIT
rm -rf "$tmp_dir"

log_info "Verificando salud del panel tras la actualización..."
health_ok="yes"
if ! php artisan --version >/dev/null 2>&1; then
  health_ok="no"
fi
if ! systemctl is-active --quiet "$php_fpm_service" || ! systemctl is-active --quiet nginx || ! systemctl is-active --quiet pteroq.service; then
  health_ok="no"
fi

if [ "$health_ok" != "yes" ]; then
  log_error "La verificación post-actualización falló. El respaldo previo sigue disponible en: $pre_backup"
  exit 1
fi

log_success "Panel actualizado correctamente."