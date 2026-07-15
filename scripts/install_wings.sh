#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

log_info "Instalación de Wings con registro directo en MariaDB del panel."

if ! command_exists docker; then
  log_info "Docker no está instalado. Ejecutando instalador oficial estable..."
  curl -fsSL https://get.docker.com | sh
else
  log_info "Docker ya está instalado; se reutilizará la instalación actual."
fi

systemctl enable --now docker
ensure_packages curl mariadb-client unzip

echo "1) Panel local en esta misma instancia"
echo "2) Panel remoto en otra instancia/servidor"
read -r -p "Selecciona el tipo de panel [1-2]: " panel_mode

panel_remote_url=""
panel_db_host=""
panel_db_port="3306"
panel_db_name="panel"
panel_db_user=""
panel_db_password=""

if [ "$panel_mode" = "1" ] && panel_installed; then
  load_panel_db_credentials
  load_runtime_config
  panel_remote_url="${PANEL_URL:-$(env_value APP_URL 2>/dev/null || true)}"
  panel_db_host="$PANEL_DB_HOST"
  panel_db_port="$PANEL_DB_PORT"
  panel_db_name="$PANEL_DB_NAME"
  panel_db_user="$PANEL_DB_USER"
  panel_db_password="$PANEL_DB_PASSWORD"
elif [ "$panel_mode" = "2" ] || [ "$panel_mode" = "1" ]; then
  if [ "$panel_mode" = "1" ]; then
    log_warn "No se detectó un panel local; se solicitarán credenciales de un panel remoto."
  fi
  panel_remote_url=$(prompt_required "URL pública del panel remoto (ej. https://panel.midominio.com): ")
  panel_db_host=$(prompt_required "Host de MariaDB del panel: ")
  panel_db_port=$(prompt_default "Puerto de MariaDB [3306]: " "3306")
  panel_db_name=$(prompt_default "Nombre de la base de datos [panel]: " "panel")
  panel_db_user=$(prompt_required "Usuario de base de datos con permisos sobre el panel: ")
  panel_db_password=$(prompt_secret_required "Contraseña del usuario de base de datos: ")
else
  log_error "Opción de panel inválida."
  exit 1
fi

node_name=$(prompt_default "Nombre del nodo [WingsNode]: " "WingsNode")
location_short=$(prompt_default "Código corto de ubicación [main]: " "main")
location_long=$(prompt_default "Nombre de la ubicación [Principal]: " "Principal")
node_fqdn=$(prompt_required "Dominio o IP pública del nodo Wings: ")
node_scheme=$(prompt_default "Esquema del nodo [http]: " "http")
node_memory=$(prompt_default "Memoria total del nodo en MB [4096]: " "4096")
node_disk=$(prompt_default "Disco total del nodo en MB [51200]: " "51200")
node_upload=$(prompt_default "Límite de subida en MB [100]: " "100")
node_daemon_port=$(prompt_default "Puerto HTTP de Wings [8080]: " "8080")
node_sftp_port=$(prompt_default "Puerto SFTP de Wings [2022]: " "2022")
allocation_ip=$(choose_ip_interactively "Selecciona la IP que Wings debe anunciar:")
allocation_port=$(prompt_default "Puerto inicial para la primera allocation [25565]: " "25565")
behind_proxy="0"

if confirm_action "¿El nodo estará detrás de un proxy reverso?"; then
  behind_proxy="1"
fi

log_info "Descargando Wings..."
mkdir -p /etc/pterodactyl /var/log/pterodactyl /var/lib/pterodactyl/volumes /var/run/wings
curl -fsSL https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /usr/local/bin/wings
chmod +x /usr/local/bin/wings

sql() {
  local query="$1"
  if [ -n "$panel_db_password" ]; then
    MYSQL_PWD="$panel_db_password" mysql -N -s -h "$panel_db_host" -P "$panel_db_port" -u "$panel_db_user" "$panel_db_name" -e "$query"
  else
    mysql -N -s -h "$panel_db_host" -P "$panel_db_port" -u "$panel_db_user" "$panel_db_name" -e "$query"
  fi
}

sql_exec() {
  local query="$1"
  if [ -n "$panel_db_password" ]; then
    MYSQL_PWD="$panel_db_password" mysql -h "$panel_db_host" -P "$panel_db_port" -u "$panel_db_user" "$panel_db_name" -e "$query"
  else
    mysql -h "$panel_db_host" -P "$panel_db_port" -u "$panel_db_user" "$panel_db_name" -e "$query"
  fi
}

location_id=$(sql "SELECT id FROM locations WHERE short = '$(sql_escape "$location_short")' LIMIT 1;")
if [ -z "$location_id" ]; then
  sql_exec "INSERT INTO locations (short, long, created_at, updated_at) VALUES ('$(sql_escape "$location_short")', '$(sql_escape "$location_long")', NOW(), NOW());"
  location_id=$(sql "SELECT id FROM locations WHERE short = '$(sql_escape "$location_short")' LIMIT 1;")
fi

mapfile -t node_columns < <(sql "SHOW COLUMNS FROM nodes;" | awk '{print $1}')
column_exists() {
  local needle="$1"
  local value=""
  for value in "${node_columns[@]}"; do
    if [ "$value" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

node_uuid=$(cat /proc/sys/kernel/random/uuid)
token_id=$(random_alnum 16)
token_value=$(random_alnum 64)

declare -a insert_columns=()
declare -a insert_values=()
append_node_field() {
  local field="$1"
  local value="$2"
  if column_exists "$field"; then
    insert_columns+=("$field")
    insert_values+=("$value")
  fi
}

append_node_field uuid "'$(sql_escape "$node_uuid")'"
append_node_field public "1"
append_node_field name "'$(sql_escape "$node_name")'"
append_node_field description "'Instalado mediante panel-installer'"
append_node_field location_id "$location_id"
append_node_field fqdn "'$(sql_escape "$node_fqdn")'"
append_node_field scheme "'$(sql_escape "$node_scheme")'"
append_node_field behind_proxy "$behind_proxy"
append_node_field maintenance_mode "0"
append_node_field memory "$node_memory"
append_node_field memory_overallocate "0"
append_node_field disk "$node_disk"
append_node_field disk_overallocate "0"
append_node_field upload_size "$node_upload"
append_node_field daemon_sftp "$node_sftp_port"
append_node_field daemon_listen "$node_daemon_port"
append_node_field daemon_base "'/var/lib/pterodactyl/volumes'"
append_node_field daemon_token_id "'$(sql_escape "$token_id")'"
append_node_field daemon_token "'$(sql_escape "$token_value")'"
append_node_field created_at "NOW()"
append_node_field updated_at "NOW()"

sql_exec "INSERT INTO nodes ($(IFS=,; echo "${insert_columns[*]}")) VALUES ($(IFS=,; echo "${insert_values[*]}"));"
node_id=$(sql "SELECT id FROM nodes WHERE uuid = '$(sql_escape "$node_uuid")' LIMIT 1;")

mapfile -t allocation_columns < <(sql "SHOW COLUMNS FROM allocations;" | awk '{print $1}')
allocation_column_exists() {
  local needle="$1"
  local value=""
  for value in "${allocation_columns[@]}"; do
    if [ "$value" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

declare -a allocation_insert_columns=()
declare -a allocation_insert_values=()
append_allocation_field() {
  local field="$1"
  local value="$2"
  if allocation_column_exists "$field"; then
    allocation_insert_columns+=("$field")
    allocation_insert_values+=("$value")
  fi
}

append_allocation_field node_id "$node_id"
append_allocation_field ip "'$(sql_escape "$allocation_ip")'"
append_allocation_field ip_alias "NULL"
append_allocation_field port "$allocation_port"
append_allocation_field assigned_to_instance_id "NULL"
append_allocation_field server_id "NULL"
append_allocation_field created_at "NOW()"
append_allocation_field updated_at "NOW()"

sql_exec "INSERT INTO allocations ($(IFS=,; echo "${allocation_insert_columns[*]}")) VALUES ($(IFS=,; echo "${allocation_insert_values[*]}"));"

cat > "$WINGS_CONFIG" <<EOF
debug: false
uuid: $node_uuid
token_id: $token_id
token: $token_value
api:
  host: 0.0.0.0
  port: $node_daemon_port
  ssl:
    enabled: false
    cert: /etc/ssl/certs/ssl-cert-snakeoil.pem
    key: /etc/ssl/private/ssl-cert-snakeoil.key
  upload_limit: $node_upload
system:
  root_directory: /var/lib/pterodactyl/volumes
  log_directory: /var/log/pterodactyl
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_address: 0.0.0.0
    bind_port: $node_sftp_port
allowed_mounts: []
remote: '$panel_remote_url'
remote_query:
  timeout: 30
EOF

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings.service

log_success "Wings instalado y registrado."
echo "Node ID: $node_id"
echo "UUID: $node_uuid"
echo "Allocation inicial: $allocation_ip:$allocation_port"#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}[*] Iniciando instalación automatizada de Wings y Docker...${NC}"

DOMINIO_NGINX=$(cat /tmp/ptero_domain 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
IP_DETECTADA=$(cat /tmp/ptero_ip 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "${AZUL}[*] Instalando Docker Daemon...${NC}"
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

echo -e "${AZUL}[*] Descargando binario de Pterodactyl Wings...${NC}"
mkdir -p /etc/pterodactyl /var/log/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod u+x /usr/local/bin/wings

echo -e "${AZUL}[*] Registrando Local Node y generando tokens internos...${NC}"
NODE_UUID=$(cat /proc/sys/kernel/random/uuid)
WINGS_TOKEN=$(openssl rand -hex 32)
WINGS_TOKEN_ID=$(openssl rand -hex 8)

mysql -u root panel -e "INSERT INTO nodes (uuid, name, location_id, public, fqdn, scheme, behind_proxy, maintenance_mode, memory, memory_overallocate, disk, disk_overallocate, upload_size, daemon_listen, daemon_sftp, daemon_token_id, daemon_token, created_at, updated_at) VALUES ('${NODE_UUID}', 'LocalNode', 1, 1, '${DOMINIO_NGINX}', 'http', 0, 0, 2048, 0, 20000, 0, 100, 8080, 2022, '${WINGS_TOKEN_ID}', '${WINGS_TOKEN}', NOW(), NOW());"

NODE_ID=$(mysql -u root panel -s -N -e "SELECT id FROM nodes WHERE uuid='${NODE_UUID}';")
mysql -u root panel -e "INSERT INTO allocations (node_id, ip, ip_alias, port, assigned_to_instance_id, created_at, updated_at) VALUES (${NODE_ID}, '${IP_DETECTADA}', NULL, 25565, NULL, NOW(), NOW());"

cat <<EOF > /etc/pterodactyl/config.yml
debug: false
uuid: ${NODE_UUID}
token_id: ${WINGS_TOKEN_ID}
token: ${WINGS_TOKEN}
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
    cert: /etc/letsencrypt/live/${DOMINIO_NGINX}/fullchain.pem
    key: /etc/letsencrypt/live/${DOMINIO_NGINX}/privkey.pem
  upload_size: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
allowed_mounts: []
EOF

cat <<EOF > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings

echo -e "\n${VERDE}==================================================${NC}"
echo -e "${VERDE}    FIN DEL SCRIPT DE INSTALACIÓN DE WINGS       ${NC}"
echo -e "${VERDE}==================================================${NC}"
echo -e "Nodo Autoregistrado: LocalNode (ID: ${NODE_ID})"
echo -e "${VERDE}==================================================${NC}"
echo -e "${AZUL}Si ves algún error arriba, haz scroll en tu consola para revisarlo.${NC}\n"
