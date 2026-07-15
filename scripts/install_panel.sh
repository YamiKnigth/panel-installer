#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive
assert_supported_panel_os

trap 'log_error "Falló la instalación del panel en la línea $LINENO: $BASH_COMMAND"' ERR

if panel_installed; then
  log_warn "Ya se detectó una instalación del panel en $PANEL_DIR."
  if confirm_action "¿Quieres continuar con una reinstalación limpia?"; then
    backup_zip=$(create_backup_archive "yes" "pre_reinstall_panel")
    log_success "Respaldo previo generado: $backup_zip"
  else
    log_info "Instalación cancelada. Usa la opción de actualización si lo que necesitas es actualizar."
    exit 0
  fi
fi

selected_ip=$(choose_ip_interactively "IPs detectadas en esta instancia Multipass:")
panel_email=$(prompt_required "Correo del administrador inicial: ")
panel_timezone=$(prompt_default "Zona horaria del panel [UTC]: " "UTC")

if confirm_action "¿Quieres habilitar HTTPS con Let's Encrypt?"; then
  use_ssl="yes"
  panel_host=$(prompt_required "Dominio público que apunta a esta instancia: ")
  panel_scheme="https"
else
  use_ssl="no"
  panel_host=$(prompt_default "Host/IP para acceder al panel [$selected_ip]: " "$selected_ip")
  panel_scheme="http"
fi

panel_url="${panel_scheme}://${panel_host}"
db_password=$(random_alnum 32)
admin_password=$(random_alnum 20)

configure_panel_nginx() {
  log_info "Aplicando configuración de Nginx..."
  rm -f /etc/nginx/sites-enabled/default

  if [ "$use_ssl" = "yes" ]; then
  systemctl stop nginx
  certbot certonly --standalone --non-interactive --agree-tos --email "$panel_email" -d "$panel_host"
  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
  listen 80;
  server_name $panel_host;
  return 301 https://\$server_name\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name $panel_host;
  root $PANEL_DIR/public;
  index index.php;
  client_max_body_size 100m;

  ssl_certificate /etc/letsencrypt/live/$panel_host/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$panel_host/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:$php_fpm_socket;
    fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
  }
}
EOF
  else
  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
  listen 80;
  server_name $panel_host;
  root $PANEL_DIR/public;
  index index.php;
  charset utf-8;
  client_max_body_size 100m;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:$php_fpm_socket;
    fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
  }
}
EOF
  fi

  ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
}

install_panel_crontab() {
  local cron_line
  local existing_crontab

  cron_line="* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1"
  existing_crontab="$(crontab -l 2>/dev/null || true)"

  {
    if [ -n "$existing_crontab" ]; then
      printf '%s\n' "$existing_crontab" | grep -F -v "$PANEL_DIR/artisan schedule:run" || true
    fi
    printf '%s\n' "$cron_line"
  } | crontab -
}

log_info "Actualizando índices de paquetes..."
apt-get update -y
php_version=$(detect_available_php_version)
php_fpm_service=$(php_fpm_service_name "$php_version")
php_fpm_socket=$(php_fpm_socket_path "$php_version")

if [ "$php_version" != "8.3" ]; then
  log_warn "PHP 8.3 no está disponible en esta imagen Ubuntu 24.04; se usará PHP $php_version, que sigue siendo compatible con la documentación oficial del panel."
fi

log_info "Instalando dependencias nativas del sistema..."
ensure_packages \
  curl \
  unzip \
  tar \
  git \
  nginx \
  redis-server \
  mariadb-server \
  mariadb-client \
  certbot \
  python3-certbot-nginx \
  ca-certificates \
  "php${php_version}" \
  "php${php_version}-cli" \
  "php${php_version}-common" \
  "php${php_version}-curl" \
  "php${php_version}-fpm" \
  "php${php_version}-gd" \
  "php${php_version}-intl" \
  "php${php_version}-mbstring" \
  "php${php_version}-mysql" \
  "php${php_version}-bcmath" \
  "php${php_version}-xml" \
  "php${php_version}-zip"

if ! command_exists composer; then
  log_info "Instalando Composer..."
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi

systemctl enable --now mariadb redis-server nginx "$php_fpm_service"

log_info "Preparando directorio del panel..."
rm -rf "$PANEL_DIR"
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"
curl -fsSL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz

configure_panel_nginx

log_info "Configurando MariaDB para el panel..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_password}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup --author="$panel_email" --url="$panel_url" --timezone="$panel_timezone" --cache="redis" --session="database" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui="yes" --telemetry="no"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$db_password"
php artisan migrate --seed --force
php artisan p:user:make --email="$panel_email" --username="admin" --name-first="Admin" --name-last="Principal" --password="$admin_password" --admin=1

chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

install_panel_crontab

cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pteroq.service
systemctl restart nginx "$php_fpm_service" redis-server mariadb pteroq.service

save_runtime_config <<EOF
PANEL_URL="$panel_url"
PANEL_HOST="$panel_host"
PANEL_IP="$selected_ip"
PANEL_SCHEME="$panel_scheme"
PANEL_PHP_VERSION="$php_version"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_DATABASE="panel"
DB_USERNAME="pterodactyl"
DB_PASSWORD="$db_password"
EOF

cat > /root/credenciales_pterodactyl.txt <<EOF
URL del panel: $panel_url
Usuario: admin
Correo: $panel_email
Contraseña temporal: $admin_password
Base de datos: panel
Usuario BD: pterodactyl
Contraseña BD: $db_password
Versión PHP usada: $php_version
EOF

log_success "Panel instalado correctamente."
echo "Credenciales guardadas en /root/credenciales_pterodactyl.txt"
cat /root/credenciales_pterodactyl.txt
