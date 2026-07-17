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

current_version=$(installed_wings_version || true)
latest_tag=$(latest_github_release_tag "pterodactyl/wings")
latest_version="${latest_tag#v}"
log_info "Versión instalada: ${current_version:-desconocida}. Última disponible: ${latest_tag:-desconocida}."

if [ -n "$current_version" ] && [ -n "$latest_version" ] && [ "$current_version" = "$latest_version" ]; then
  log_success "Wings ya está en la última versión ($current_version). No es necesario actualizar."
  exit 0
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

wings_arch=$(wings_binary_arch)
log_info "Descargando la última versión de Wings (arquitectura $wings_arch)..."
curl -fsSL "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${wings_arch}" -o "$tmp_binary"
chmod u+x "$tmp_binary"

version_output=$("$tmp_binary" --version 2>&1) || {
  log_error "El binario descargado de Wings no pasó la verificación (--version falló). No se detendrá el servicio actual."
  log_error "Salida: $version_output"
  exit 1
}
log_info "Binario descargado reporta: $version_output"

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