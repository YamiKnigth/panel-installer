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

if ! command_exists docker; then
  log_info "Docker no está presente. Instalando con get.docker.com..."
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

tmp_binary=$(mktemp)
trap 'rm -f "$tmp_binary"' EXIT

log_info "Descargando la última versión de Wings..."
curl -fsSL https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o "$tmp_binary"
chmod +x "$tmp_binary"

if ! "$tmp_binary" --version >/dev/null 2>&1; then
  log_error "El binario descargado de Wings no pasó la verificación (--version falló). No se detendrá el servicio actual."
  exit 1
fi

log_info "Binario verificado. Deteniendo Wings para reemplazarlo..."
systemctl stop wings.service
mv "$tmp_binary" /usr/local/bin/wings
trap - EXIT

systemctl daemon-reload
systemctl start wings.service

if ! systemctl is-active --quiet wings.service; then
  log_error "Wings no quedó activo tras la actualización. Revisa: journalctl -u wings -n 50"
  exit 1
fi

log_success "Wings actualizado correctamente."