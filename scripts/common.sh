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

os_release_value() {
  local key="$1"

  if [ ! -f /etc/os-release ]; then
    return 1
  fi

  sed -n "s/^${key}=//p" /etc/os-release | head -n 1 | tr -d '"'
}

assert_supported_panel_os() {
  local distro version codename

  distro="$(os_release_value ID || true)"
  version="$(os_release_value VERSION_ID || true)"
  codename="$(os_release_value VERSION_CODENAME || true)"

  if [ "$distro" != "ubuntu" ] || [ "$version" != "24.04" ]; then
    log_error "Este instalador del panel está diseñado para Ubuntu 24.04. Sistema detectado: ${distro:-desconocido} ${version:-desconocido} ${codename:-}."
    log_error "La documentación oficial de Pterodactyl para el panel requiere PHP 8.2 o 8.3; si tu imagen no es Ubuntu 24.04 estable, los paquetes nativos pueden no existir."
    exit 1
  fi
}

ensure_official_php_repository() {
  local matches=""

  matches="$(apt-cache search '^php8\.[23]-fpm$' 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    return
  fi

  log_info "No se detectaron paquetes PHP 8.2/8.3. Habilitando el componente oficial universe de Ubuntu..."
  apt-get install -y software-properties-common
  add-apt-repository -y universe
  apt-get update -y
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
  apt-get update -y >/dev/null
  apt-get install -y "${missing[@]}" >/dev/null
}

sql_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/'\''/'\'''\''/g'
}

panel_db_reachable() {
  local db_host="$1" db_port="$2" db_name="$3" db_user="$4" db_password="$5"
  local error_output=""

  if [ -n "$db_password" ]; then
    error_output=$(MYSQL_PWD="$db_password" mysql -N -s -h "$db_host" -P "$db_port" -u "$db_user" "$db_name" -e "SELECT 1;" 2>&1)
  else
    error_output=$(mysql -N -s -h "$db_host" -P "$db_port" -u "$db_user" "$db_name" -e "SELECT 1;" 2>&1)
  fi

  if [ $? -eq 0 ]; then
    return 0
  fi

  if printf '%s' "$error_output" | grep -qi "access denied"; then
    log_error "Acceso denegado a MariaDB para el usuario '$db_user'. Verifica usuario/contraseña."
  elif printf '%s' "$error_output" | grep -qi "unknown database"; then
    log_error "La base de datos '$db_name' no existe en $db_host:$db_port."
  elif printf '%s' "$error_output" | grep -qiE "can't connect|connection refused|no route to host|timed out"; then
    log_error "No se pudo conectar a MariaDB en $db_host:$db_port. Verifica conectividad de red y que el servicio esté escuchando."
  else
    log_error "Fallo al validar la conexión a la base de datos del panel: $error_output"
  fi

  return 1
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
  local candidate=""

  for version in 8.3 8.2; do
    candidate="$(apt-cache policy "php${version}-fpm" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' || true)"
    if [ -n "$candidate" ] && [ "$candidate" != "(none)" ]; then
      printf '%s' "$version"
      return
    fi
  done

  log_error "No se encontró PHP 8.2 ni PHP 8.3 en los repositorios APT nativos de esta instancia."
  log_error "Según la documentación oficial de Pterodactyl, el panel requiere PHP 8.2 o 8.3."
  log_error "Verifica que la instancia sea Ubuntu 24.04 estable y no una imagen distinta o de desarrollo."
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

  for version in 8.3 8.2; do
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

  if ! unzip -tq "$backup_zip" >/dev/null 2>&1; then
    log_error "El archivo de respaldo generado no pasó la verificación de integridad: $backup_zip"
    rm -f "$backup_zip"
    exit 1
  fi

  rotate_old_backups "$context_label"
  printf '%s' "$backup_zip"
}

create_wings_only_backup_archive() {
  local context_label="$1"
  local timestamp backup_dir backup_zip

  timestamp=$(date +%F_%H-%M-%S)
  backup_dir="/tmp/pterodactyl_backup_${context_label}_wings_${timestamp}"
  backup_zip="/tmp/pterodactyl_backup_${context_label}_wings_${timestamp}.zip"
  mkdir -p "$backup_dir"

  cp "$WINGS_CONFIG" "$backup_dir/wings.config.yml"
  [ -f "$RUNTIME_FILE" ] && cp "$RUNTIME_FILE" "$backup_dir/runtime.conf"

  cat > "$backup_dir/RESTORE.txt" <<EOF
Contenido del respaldo:
- wings.config.yml: configuración de Wings
- runtime.conf: metadatos locales del instalador, si aplica
EOF

  ensure_packages zip unzip
  (
    cd "$backup_dir"
    zip -rq "$backup_zip" .
  )
  rm -rf "$backup_dir"

  if ! unzip -tq "$backup_zip" >/dev/null 2>&1; then
    log_error "El archivo de respaldo generado no pasó la verificación de integridad: $backup_zip"
    rm -f "$backup_zip"
    exit 1
  fi

  rotate_old_backups "${context_label}_wings"
  printf '%s' "$backup_zip"
}

rotate_old_backups() {
  local context_label="$1"
  local keep="${BACKUP_RETENTION_COUNT:-5}"
  local old=""

  mapfile -t old < <(ls -1t /tmp/pterodactyl_backup_"${context_label}"_*.zip 2>/dev/null | tail -n +$((keep + 1)))
  for old_file in "${old[@]:-}"; do
    [ -n "$old_file" ] && [ -f "$old_file" ] && rm -f "$old_file"
  done
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