#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

trap 'log_error "Falló la instalación de Wings en la línea $LINENO: $BASH_COMMAND"' ERR

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
panel_app_key=""
use_local_crypto="no"

validate_app_key() {
  local key="$1"
  local decoded_len

  if [[ "$key" != base64:* ]]; then
    log_error "El APP_KEY debe comenzar con el prefijo 'base64:'."
    return 1
  fi

  decoded_len=$(printf '%s' "${key#base64:}" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
  if [ "$decoded_len" != "32" ]; then
    log_error "El APP_KEY decodificado debe tener 32 bytes (tiene $decoded_len). Verifica que copiaste el valor completo."
    return 1
  fi

  return 0
}

if [ "$panel_mode" = "1" ] && panel_installed; then
  load_panel_db_credentials
  load_runtime_config
  panel_remote_url="${PANEL_URL:-$(env_value APP_URL 2>/dev/null || true)}"
  panel_db_host="$PANEL_DB_HOST"
  panel_db_port="$PANEL_DB_PORT"
  panel_db_name="$PANEL_DB_NAME"
  panel_db_user="$PANEL_DB_USER"
  panel_db_password="$PANEL_DB_PASSWORD"
  panel_app_key="$(env_value APP_KEY "$PANEL_DIR/.env" 2>/dev/null || true)"

  if [ -f "$PANEL_DIR/vendor/autoload.php" ] && [ -f "$PANEL_DIR/bootstrap/app.php" ]; then
    use_local_crypto="yes"
  else
    log_warn "No se encontró vendor/autoload.php en el panel local; se usará el cifrado manual de respaldo."
  fi
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
  log_info "El APP_KEY está en /var/www/pterodactyl/.env del servidor del panel."
  panel_app_key=$(prompt_required "APP_KEY del panel (valor completo, ej. base64:XXXX...): ")
else
  log_error "Opción de panel inválida."
  exit 1
fi

if [ -z "$panel_app_key" ]; then
  log_error "No se pudo obtener el APP_KEY del panel. Es necesario para cifrar los tokens del nodo."
  exit 1
fi

if ! validate_app_key "$panel_app_key"; then
  exit 1
fi

log_info "Verificando conectividad con la base de datos del panel..."
if ! panel_db_reachable "$panel_db_host" "$panel_db_port" "$panel_db_name" "$panel_db_user" "$panel_db_password"; then
  exit 1
fi
log_success "Conexión a la base de datos del panel verificada."

node_name=$(prompt_default "Nombre del nodo [WingsNode]: " "WingsNode")
location_short=$(prompt_default "Código corto de ubicación [main]: " "main")
location_long=$(prompt_default "Nombre de la ubicación [Principal]: " "Principal")
node_fqdn=$(prompt_required "Dominio o IP pública del nodo Wings: ")

node_scheme=""
while true; do
  node_scheme=$(prompt_default "Esquema del nodo [http]: " "http")
  [[ "$node_scheme" =~ ^(http|https)$ ]] && break
  log_warn "El esquema debe ser 'http' o 'https'."
done

node_memory=$(prompt_default "Memoria total del nodo en MB [4096]: " "4096")
node_disk=$(prompt_default "Disco total del nodo en MB [51200]: " "51200")
node_upload=$(prompt_default "Límite de subida en MB [100]: " "100")

prompt_valid_port() {
  local prompt_message="$1" default_value="$2" value=""

  while true; do
    value=$(prompt_default "$prompt_message" "$default_value")
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
      printf '%s' "$value"
      return
    fi
    log_warn "Ingresa un puerto numérico válido (1-65535)." >&2
  done
}

node_daemon_port=$(prompt_valid_port "Puerto HTTP de Wings [8080]: " "8080")
node_sftp_port=$(prompt_valid_port "Puerto SFTP de Wings [2022]: " "2022")
allocation_ip=$(choose_ip_interactively "Selecciona la IP que Wings debe anunciar:")
allocation_port=$(prompt_valid_port "Puerto inicial para la primera allocation [25565]: " "25565")
behind_proxy="0"

if confirm_action "¿El nodo estará detrás de un proxy reverso?"; then
  behind_proxy="1"
fi

log_info "Descargando Wings..."
mkdir -p /etc/pterodactyl /var/log/pterodactyl /var/lib/pterodactyl/volumes /var/run/wings
curl -fsSL https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /usr/local/bin/wings
chmod +x /usr/local/bin/wings

node_uuid=$(cat /proc/sys/kernel/random/uuid)
token_id=$(random_alnum 16)
token_value=$(random_alnum 64)

work_dir=$(mktemp -d)
location_created="no"
node_created="no"
node_id=""
install_succeeded="no"

cleanup_and_rollback() {
  local status=$?

  if [ "$install_succeeded" != "yes" ]; then
    if [ -n "$node_id" ] && [ "$node_created" = "yes" ]; then
      log_warn "Revirtiendo inserción parcial: eliminando nodo id=$node_id."
      sql_exec "DELETE FROM allocations WHERE node_id = $node_id;" || true
      sql_exec "DELETE FROM nodes WHERE id = $node_id;" || true
    fi
    if [ "$location_created" = "yes" ] && [ -n "${location_id:-}" ]; then
      if [ "$(sql "SELECT COUNT(*) FROM nodes WHERE location_id = $location_id;")" = "0" ]; then
        log_warn "Revirtiendo inserción parcial: eliminando location id=$location_id."
        sql_exec "DELETE FROM locations WHERE id = $location_id;" || true
      fi
    fi
  fi

  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup_and_rollback EXIT

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

join_csv() { local IFS=,; echo "$*"; }

# --- Cifrado de tokens: Node::getDecryptedKey() llama al Encrypter genérico sobre
# daemon_token (NO usa el cast 'encrypted' de Eloquent ni encryptString/decryptString).
# El helper encrypt()/decrypt() genérico SÍ serializa el valor antes de cifrar
# (a diferencia de encryptString, que no serializa) — hay que igualar ese formato o
# el panel revienta con "unserialize(): Error at offset 0" al decodificar el nodo.
# daemon_token_id, en cambio, se guarda en texto plano (no se cifra ni se decodifica
# en ningún punto del modelo).
#
# Camino local: bootea la app Laravel real del panel e invoca Crypt::encrypt/decrypt
# directamente, garantizando compatibilidad exacta con la versión de Laravel/cifrado instalada.
#
# Camino remoto (respaldo): reimplementa el formato de Illuminate\Encryption\Encrypter a mano.
# IMPORTANTE: el MAC es hash_hmac('sha256', $iv.$value, $key) en hexadecimal plano (sin base64,
# sin flag "raw"), y el valor SÍ se serializa con serialize()/unserialize() antes/después del
# cifrado (formato del helper encrypt() genérico, no el de encryptString).

if [ "$use_local_crypto" = "yes" ]; then
  crypto_script="$work_dir/laravel_crypto.php"
  cat > "$crypto_script" << PHPEOF
<?php
require '$PANEL_DIR/vendor/autoload.php';
\$app = require '$PANEL_DIR/bootstrap/app.php';
\$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

\$mode = \$argv[1];
\$in = trim(file_get_contents('php://stdin'));

try {
    if (\$mode === 'encrypt') {
        echo Illuminate\Support\Facades\Crypt::encrypt(\$in);
    } else {
        echo Illuminate\Support\Facades\Crypt::decrypt(\$in);
    }
} catch (Throwable \$e) {
    fwrite(STDERR, \$e->getMessage());
    exit(1);
}
PHPEOF

  encrypt_token() {
    (cd "$PANEL_DIR" && php "$crypto_script" encrypt <<< "$1")
  }

  decrypt_token() {
    (cd "$PANEL_DIR" && php "$crypto_script" decrypt <<< "$1")
  }
else
  crypto_script="$work_dir/manual_crypto.php"
  cat > "$crypto_script" << 'PHPEOF'
<?php
$appKey = getenv('PTERO_APP_KEY');
if (strncmp($appKey, 'base64:', 7) === 0) {
    $appKey = base64_decode(substr($appKey, 7));
}
if (strlen($appKey) !== 32) {
    fwrite(STDERR, 'Error: APP_KEY decodificado debe tener 32 bytes. Longitud: ' . strlen($appKey) . PHP_EOL);
    exit(1);
}

function laravel_encrypt(string $value, string $key): string {
    $serialized = serialize($value);
    $iv = random_bytes(16);
    $encrypted = openssl_encrypt($serialized, 'AES-256-CBC', $key, 0, $iv);
    if ($encrypted === false) {
        fwrite(STDERR, 'openssl_encrypt falló: ' . openssl_error_string() . PHP_EOL);
        exit(1);
    }
    $ivBase64 = base64_encode($iv);
    $mac = hash_hmac('sha256', $ivBase64 . $encrypted, $key);
    return base64_encode(json_encode(['iv' => $ivBase64, 'value' => $encrypted, 'mac' => $mac, 'tag' => '']));
}

function laravel_decrypt(string $payload, string $key): string {
    $data = json_decode(base64_decode($payload), true);
    if (!is_array($data) || !isset($data['iv'], $data['value'], $data['mac'])) {
        fwrite(STDERR, 'Payload cifrado con formato inválido.' . PHP_EOL);
        exit(1);
    }
    $calculatedMac = hash_hmac('sha256', $data['iv'] . $data['value'], $key);
    if (!hash_equals($calculatedMac, $data['mac'])) {
        fwrite(STDERR, 'MAC is invalid.' . PHP_EOL);
        exit(1);
    }
    $decrypted = openssl_decrypt($data['value'], 'AES-256-CBC', $key, 0, base64_decode($data['iv']));
    if ($decrypted === false) {
        fwrite(STDERR, 'openssl_decrypt falló: ' . openssl_error_string() . PHP_EOL);
        exit(1);
    }
    $value = unserialize($decrypted);
    if ($value === false && $decrypted !== serialize(false)) {
        fwrite(STDERR, 'unserialize falló al decodificar el valor.' . PHP_EOL);
        exit(1);
    }
    return $value;
}

$mode = $argv[1];
$in = trim(file_get_contents('php://stdin'));
echo $mode === 'encrypt' ? laravel_encrypt($in, $appKey) : laravel_decrypt($in, $appKey);
PHPEOF

  encrypt_token() {
    PTERO_APP_KEY="$panel_app_key" php "$crypto_script" encrypt <<< "$1"
  }

  decrypt_token() {
    PTERO_APP_KEY="$panel_app_key" php "$crypto_script" decrypt <<< "$1"
  }
fi

log_info "Cifrando tokens ($([ "$use_local_crypto" = "yes" ] && echo "vía Laravel local" || echo "vía cifrado manual"))..."

enc_token=$(encrypt_token "$token_value")

log_info "Verificando cifrado mediante prueba de round-trip..."
roundtrip_token=$(decrypt_token "$enc_token")

if [ "$roundtrip_token" != "$token_value" ]; then
  log_error "El cifrado de tokens no superó la verificación de round-trip; abortando antes de tocar la base de datos."
  exit 1
fi
log_success "Cifrado de tokens verificado correctamente."

mapfile -t location_columns < <(sql "SHOW COLUMNS FROM locations;" | awk '{print $1}')
location_column_exists() {
  local needle="$1" value=""
  for value in "${location_columns[@]}"; do [ "$value" = "$needle" ] && return 0; done
  return 1
}

location_id=$(sql "SELECT id FROM locations WHERE short = '$(sql_escape "$location_short")' LIMIT 1;")
if [ -z "$location_id" ]; then
  if location_column_exists "long"; then loc_name_col="long"
  elif location_column_exists "name"; then loc_name_col="name"
  else log_error "La tabla locations no tiene columna 'long' ni 'name'."; exit 1; fi

  declare -a loc_cols=() loc_vals=()
  loc_cols+=("\`short\`");            loc_vals+=("'$(sql_escape "$location_short")'")
  loc_cols+=("\`${loc_name_col}\`");  loc_vals+=("'$(sql_escape "$location_long")'")
  location_column_exists "created_at" && { loc_cols+=("\`created_at\`"); loc_vals+=("NOW()"); }
  location_column_exists "updated_at" && { loc_cols+=("\`updated_at\`"); loc_vals+=("NOW()"); }
  sql_exec "INSERT INTO locations ($(join_csv "${loc_cols[@]}")) VALUES ($(join_csv "${loc_vals[@]}"));"
  location_id=$(sql "SELECT id FROM locations WHERE short = '$(sql_escape "$location_short")' LIMIT 1;")
  location_created="yes"
else
  log_info "Reutilizando ubicación existente '$location_short' (id=$location_id)."
fi

existing_node_id=$(sql "SELECT id FROM nodes WHERE fqdn = '$(sql_escape "$node_fqdn")' LIMIT 1;")
if [ -n "$existing_node_id" ]; then
  log_warn "Ya existe un nodo con fqdn '$node_fqdn' (id=$existing_node_id)."
  if ! confirm_action "¿Continuar de todas formas y crear un nodo adicional con el mismo fqdn?"; then
    log_info "Instalación cancelada por el usuario."
    exit 0
  fi
fi

existing_allocation=$(sql "SELECT id FROM allocations WHERE ip = '$(sql_escape "$allocation_ip")' AND port = $allocation_port LIMIT 1;")
if [ -n "$existing_allocation" ]; then
  log_error "Ya existe una allocation para $allocation_ip:$allocation_port. Elige otro puerto o IP."
  exit 1
fi

mapfile -t node_columns < <(sql "SHOW COLUMNS FROM nodes;" | awk '{print $1}')
node_column_exists() {
  local needle="$1" value=""
  for value in "${node_columns[@]}"; do [ "$value" = "$needle" ] && return 0; done
  return 1
}

declare -a node_cols=() node_vals=()
append_node_field() {
  local field="$1" value="$2"
  if node_column_exists "$field"; then node_cols+=("\`${field}\`"); node_vals+=("$value"); fi
}

append_node_field uuid               "'$(sql_escape "$node_uuid")'"
append_node_field public             "1"
append_node_field name               "'$(sql_escape "$node_name")'"
append_node_field description        "'Instalado mediante panel-installer'"
append_node_field location_id        "$location_id"
append_node_field fqdn               "'$(sql_escape "$node_fqdn")'"
append_node_field scheme             "'$(sql_escape "$node_scheme")'"
append_node_field behind_proxy       "$behind_proxy"
append_node_field maintenance_mode   "0"
append_node_field memory             "$node_memory"
append_node_field memory_overallocate "0"
append_node_field disk               "$node_disk"
append_node_field disk_overallocate  "0"
append_node_field upload_size        "$node_upload"
append_node_field daemon_sftp        "$node_sftp_port"
append_node_field daemon_listen      "$node_daemon_port"
append_node_field daemon_base        "'/var/lib/pterodactyl/volumes'"
append_node_field daemon_token_id    "'$(sql_escape "$token_id")'"
append_node_field daemon_token       "'$(sql_escape "$enc_token")'"
append_node_field created_at         "NOW()"
append_node_field updated_at         "NOW()"

sql_exec "INSERT INTO nodes ($(join_csv "${node_cols[@]}")) VALUES ($(join_csv "${node_vals[@]}"));"
node_id=$(sql "SELECT id FROM nodes WHERE uuid = '$(sql_escape "$node_uuid")' LIMIT 1;")
node_created="yes"

log_info "Verificando que los tokens almacenados en la base de datos coincidan con los generados..."
stored_token_id=$(sql "SELECT daemon_token_id FROM nodes WHERE id = $node_id;")
stored_token=$(sql "SELECT daemon_token FROM nodes WHERE id = $node_id;")

if [ "$stored_token_id" != "$token_id" ] || [ "$stored_token" != "$enc_token" ]; then
  log_error "Los tokens almacenados en la base de datos no coinciden con los generados (posible corrupción al insertar). Abortando y revirtiendo."
  exit 1
fi
log_success "Tokens verificados en base de datos correctamente."

mapfile -t alloc_columns < <(sql "SHOW COLUMNS FROM allocations;" | awk '{print $1}')
alloc_column_exists() {
  local needle="$1" value=""
  for value in "${alloc_columns[@]}"; do [ "$value" = "$needle" ] && return 0; done
  return 1
}

declare -a alloc_cols=() alloc_vals=()
append_alloc_field() {
  local field="$1" value="$2"
  if alloc_column_exists "$field"; then alloc_cols+=("\`${field}\`"); alloc_vals+=("$value"); fi
}

append_alloc_field node_id                  "$node_id"
append_alloc_field ip                       "'$(sql_escape "$allocation_ip")'"
append_alloc_field ip_alias                 "NULL"
append_alloc_field port                     "$allocation_port"
append_alloc_field assigned_to_instance_id  "NULL"
append_alloc_field server_id                "NULL"
append_alloc_field created_at               "NOW()"
append_alloc_field updated_at               "NOW()"

sql_exec "INSERT INTO allocations ($(join_csv "${alloc_cols[@]}")) VALUES ($(join_csv "${alloc_vals[@]}"));"

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
chmod 600 "$WINGS_CONFIG"

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

install_succeeded="yes"

log_success "Wings instalado y registrado."
echo "Node ID   : $node_id"
echo "UUID      : $node_uuid"
echo "Allocation: $allocation_ip:$allocation_port"
