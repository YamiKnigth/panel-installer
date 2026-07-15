#!/bin/bash

set -Eeuo pipefail

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
NC='\033[0m'

RUNTIME_DIR="/etc/panel-installer"
RUNTIME_FILE="$RUNTIME_DIR/runtime.conf"
PANEL_DIR="/var/www/pterodactyl"
WINGS_CONFIG="/etc/pterodactyl/config.yml"

log_info() {
  echo -e "${AZUL}[*] $*${NC}" >&2
}

log_warn() {
  echo -e "${AMARILLO}[!] $*${NC}" >&2
}

log_error() {
  echo -e "${ROJO}[!] $*${NC}" >&2
}

log_success() {
  echo -e "${VERDE}[+] $*${NC}" >&2
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "Este script requiere privilegios de root."
    exit 1
  fi
}

ensure_noninteractive() {
  export DEBIAN_FRONTEND=noninteractive
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

random_alnum() {
  local length="$1"
  local value=""

  while [ "${#value}" -lt "$length" ]; do
    value="${value}$(openssl rand -hex "$length")"
    value=$(printf '%s' "$value" | tr -dc 'A-Za-z0-9')
  done

  printf '%s' "${value:0:length}"
}

prompt_required() {
  local prompt="$1"
  local value=""

  while [ -z "$value" ]; do
    read -r -p "$prompt" value
  done

  printf '%s' "$value"
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  read -r -p "$prompt" value
  printf '%s' "${value:-$default_value}"
}

prompt_secret_required() {
  local prompt="$1"
  local value=""

  while [ -z "$value" ]; do
    read -r -s -p "$prompt" value
    echo
  done

  printf '%s' "$value"
}

confirm_action() {
  local prompt="$1"
  local answer=""

  while true; do
    read -r -p "$prompt [s/N]: " answer
    case "${answer,,}" in
      s|si|sí|y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) log_warn "Responde s o n." ;;
    esac
  done
}

ensure_packages() {
  local packages=("$@")
  local missing=()
  local package=""

  for package in "${packages[@]}"; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  log_info "Instalando dependencias necesarias: ${missing[*]}"
  apt-get update -y
  apt-get install -y "${missing[@]}"
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

collect_ip_candidates() {
  ip -o -4 addr show scope global | awk '$2 !~ /^(docker|veth|br-|lo)/ {split($4, addr, "/"); print $2"|"$4"|"addr[1]}' | awk -F'|' '!seen[$3]++'
}

choose_ip_interactively() {
  local prompt_message="$1"
  mapfile -t candidates < <(collect_ip_candidates)

  if [ "${#candidates[@]}" -eq 0 ]; then
    log_error "No se detectaron IPs IPv4 globales en la instancia."
    exit 1
  fi

  echo "$prompt_message" >&2
  local index=1
  local entry=""
  for entry in "${candidates[@]}"; do
    IFS='|' read -r iface cidr addr <<< "$entry"
    echo "  $index) $addr ($iface - $cidr)" >&2
    index=$((index + 1))
  done

  local selected=""
  while true; do
    read -r -p "Elige una IP [1-${#candidates[@]}]: " selected
    if [[ "$selected" =~ ^[0-9]+$ ]] && [ "$selected" -ge 1 ] && [ "$selected" -le "${#candidates[@]}" ]; then
      IFS='|' read -r _ _ addr <<< "${candidates[$((selected - 1))]}"
      printf '%s' "$addr"
      return
    fi
    log_warn "Selección inválida."
  done
}

detect_available_php_version() {
  local version=""

  for version in 8.3 8.4 8.2; do
    if apt-cache show "php${version}-fpm" >/dev/null 2>&1; then
      printf '%s' "$version"
      return
    fi
  done

  log_error "No se encontró una versión soportada de PHP-FPM en los repositorios nativos."
  exit 1
}

resolve_panel_php_version() {
  local version="${1:-}"

  if [ -n "$version" ]; then
    printf '%s' "$version"
    return
  fi

  load_runtime_config

  if [ -n "${PANEL_PHP_VERSION:-}" ]; then
    printf '%s' "$PANEL_PHP_VERSION"
    return
  fi

  for version in 8.4 8.3 8.2; do
    if dpkg -s "php${version}-fpm" >/dev/null 2>&1; then
      printf '%s' "$version"
      return
    fi
  done

  detect_available_php_version
}

php_fpm_service_name() {
  local version
  version=$(resolve_panel_php_version "${1:-}")
  printf 'php%s-fpm' "$version"
}

php_fpm_socket_path() {
  local version
  version=$(resolve_panel_php_version "${1:-}")
  printf '/run/php/php%s-fpm.sock' "$version"
}

save_runtime_config() {
  mkdir -p "$RUNTIME_DIR"
  cat > "$RUNTIME_FILE"
}

load_runtime_config() {
  if [ -f "$RUNTIME_FILE" ]; then
    # shellcheck disable=SC1090
    source "$RUNTIME_FILE"
  fi
}

env_value() {
  local key="$1"
  local env_file="${2:-$PANEL_DIR/.env}"

  if [ ! -f "$env_file" ]; then
    return 1
  fi

  sed -n "s/^${key}=//p" "$env_file" | tail -n 1 | tr -d '"'
}

load_panel_db_credentials() {
  PANEL_DB_HOST="$(env_value DB_HOST 2>/dev/null || true)"
  PANEL_DB_PORT="$(env_value DB_PORT 2>/dev/null || true)"
  PANEL_DB_NAME="$(env_value DB_DATABASE 2>/dev/null || true)"
  PANEL_DB_USER="$(env_value DB_USERNAME 2>/dev/null || true)"
  PANEL_DB_PASSWORD="$(env_value DB_PASSWORD 2>/dev/null || true)"

  load_runtime_config

  PANEL_DB_HOST="${PANEL_DB_HOST:-${DB_HOST:-127.0.0.1}}"
  PANEL_DB_PORT="${PANEL_DB_PORT:-${DB_PORT:-3306}}"
  PANEL_DB_NAME="${PANEL_DB_NAME:-${DB_DATABASE:-panel}}"
  PANEL_DB_USER="${PANEL_DB_USER:-${DB_USERNAME:-pterodactyl}}"
  PANEL_DB_PASSWORD="${PANEL_DB_PASSWORD:-${DB_PASSWORD:-}}"
}

run_panel_mysql() {
  local sql="$1"
  load_panel_db_credentials

  if [ -n "$PANEL_DB_PASSWORD" ]; then
    MYSQL_PWD="$PANEL_DB_PASSWORD" mysql -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" -e "$sql"
  else
    mysql -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" -e "$sql"
  fi
}

run_panel_mysql_single() {
  local sql="$1"
  load_panel_db_credentials

  if [ -n "$PANEL_DB_PASSWORD" ]; then
    MYSQL_PWD="$PANEL_DB_PASSWORD" mysql -N -s -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" -e "$sql"
  else
    mysql -N -s -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" -e "$sql"
  fi
}

create_backup_archive() {
  local include_wings="$1"
  local context_label="$2"
  local timestamp backup_dir backup_zip

  load_panel_db_credentials

  timestamp=$(date +%F_%H-%M-%S)
  backup_dir="/tmp/pterodactyl_backup_${context_label}_${timestamp}"
  backup_zip="/tmp/pterodactyl_backup_${context_label}_${timestamp}.zip"
  mkdir -p "$backup_dir"

  if [ -f "$PANEL_DIR/.env" ]; then
    log_info "Exportando base de datos del panel..."
    if [ -n "$PANEL_DB_PASSWORD" ]; then
      MYSQL_PWD="$PANEL_DB_PASSWORD" mysqldump -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" > "$backup_dir/panel.sql"
    else
      mysqldump -h "$PANEL_DB_HOST" -P "$PANEL_DB_PORT" -u "$PANEL_DB_USER" "$PANEL_DB_NAME" > "$backup_dir/panel.sql"
    fi
    cp "$PANEL_DIR/.env" "$backup_dir/panel.env"
  else
    log_warn "No se encontró $PANEL_DIR/.env. Se omitirá el respaldo del panel."
  fi

  if [ "$include_wings" = "yes" ] && [ -f "$WINGS_CONFIG" ]; then
    cp "$WINGS_CONFIG" "$backup_dir/wings.config.yml"
  fi

  if [ -f "$RUNTIME_FILE" ]; then
    cp "$RUNTIME_FILE" "$backup_dir/runtime.conf"
  fi

  cat > "$backup_dir/RESTORE.txt" <<EOF
Contenido del respaldo:
- panel.sql: volcado de la base de datos del panel
- panel.env: archivo .env del panel
- wings.config.yml: configuración de Wings, si aplica
- runtime.conf: metadatos locales del instalador
EOF

  ensure_packages zip unzip curl mariadb-client
  (
    cd "$backup_dir"
    zip -rq "$backup_zip" .
  )
  rm -rf "$backup_dir"
  printf '%s' "$backup_zip"
}

upload_backup_archive() {
  local archive_path="$1"
  local response url

  log_info "Subiendo respaldo a bashupload.com..."
  response=$(curl -fsS --upload-file "$archive_path" "https://bashupload.com/$(basename "$archive_path")")
  url=$(printf '%s\n' "$response" | grep -Eo 'https?://[^ ]+' | head -n 1 || true)

  if [ -n "$url" ]; then
    printf '%s\n%s' "$url" "$response"
    return
  fi

  printf '%s' "$response"
}

panel_installed() {
  [ -f "$PANEL_DIR/.env" ] && [ -f "$PANEL_DIR/artisan" ]
}

wings_installed() {
  [ -f "$WINGS_CONFIG" ] && command_exists wings
}