#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

if ! wings_installed; then
  log_error "No se encontró una instalación de Wings en este sistema."
  exit 1
fi

pre_backup=$(create_backup_archive "yes" "pre_update_wings")
log_success "Respaldo previo generado: $pre_backup"

if upload_output=$(upload_backup_archive "$pre_backup"); then
  upload_url=$(printf '%s\n' "$upload_output" | head -n 1)
  if [[ "$upload_url" =~ ^https?:// ]]; then
    log_success "Respaldo remoto disponible en: $upload_url"
  fi
else
  log_warn "La subida automática del respaldo falló. El archivo local permanece en: $pre_backup"
fi

if ! command_exists docker; then
  log_info "Docker no está presente. Instalando con get.docker.com..."
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker
systemctl stop wings.service
curl -fsSL https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /usr/local/bin/wings
chmod +x /usr/local/bin/wings
systemctl daemon-reload
systemctl start wings.service

log_success "Wings actualizado correctamente."