#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_root
ensure_noninteractive

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

log_info "Instalando dependencias nativas de Ubuntu 24.04..."
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
  php8.3 \
  php8.3-cli \
  php8.3-common \
  php8.3-curl \
  php8.3-fpm \
  php8.3-gd \
  php8.3-intl \
  php8.3-mbstring \
  php8.3-mysql \
  php8.3-bcmath \
  php8.3-xml \
  php8.3-zip

if ! command_exists composer; then
  log_info "Instalando Composer..."
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi

systemctl enable --now mariadb redis-server nginx php8.3-fpm

log_info "Preparando directorio del panel..."
rm -rf "$PANEL_DIR"
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"
curl -fsSL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz

log_info "Configurando MariaDB para el panel..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_password}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup --author="$panel_email" --url="$panel_url" --timezone="$panel_timezone" --cache="redis" --session="database" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui="yes" --telemetry="no"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$db_password"
php artisan migrate --seed --force
php artisan p:user:make --email="$panel_email" --username="admin" --name-first="Admin" --name-last="Principal" --password="$admin_password" --admin=1

chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

crontab -l 2>/dev/null | grep -v "$PANEL_DIR/artisan schedule:run" | {
  cat
  echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1"
} | crontab -

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
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
}
EOF
fi

ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl daemon-reload
systemctl enable --now pteroq.service
systemctl restart nginx php8.3-fpm redis-server mariadb pteroq.service

save_runtime_config <<EOF
PANEL_URL="$panel_url"
PANEL_HOST="$panel_host"
PANEL_IP="$selected_ip"
PANEL_SCHEME="$panel_scheme"
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
EOF

log_success "Panel instalado correctamente."
echo "Credenciales guardadas en /root/credenciales_pterodactyl.txt"
cat /root/credenciales_pterodactyl.txt#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}[*] Iniciando instalación oficial del Panel Pterodactyl (Ubuntu 24.04 Nativo)...${NC}"

IP_DETECTADA=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
PASS_DB=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
PASS_ADMIN=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')

read -p "Introduce el correo electrónico para el Administrador: " EMAIL_ADMIN
read -p "¿Deseas instalar un certificado SSL gratuito (HTTPS)? (y/n): " USAR_SSL

if [[ "$USAR_SSL" == "y" ]]; then
    read -p "Introduce tu dominio apuntado a esta máquina (ej. panel.tudominio.com): " DOMINIO
    URL_PANEL="https://$DOMINIO"
    DOMINIO_NGINX="$DOMINIO"
else
    read -p "Confirma la IP o dominio local para el acceso [Por defecto: $IP_DETECTADA]: " DOMINIO_INPUT
    DOMINIO_NGINX=${DOMINIO_INPUT:-$IP_DETECTADA}
    URL_PANEL="http://$DOMINIO_NGINX"
fi

export DEBIAN_FRONTEND=noninteractive

echo -e "${AZUL}[*] Actualizando sistema e instalando dependencias base...${NC}"
apt update -y && apt upgrade -y
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg certbot python3-certbot-nginx zip unzip tar git

echo -e "${AZUL}[*] Instalando Nginx, MariaDB, Redis y PHP 8.3 uno por uno...${NC}"
apt -y install php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip mariadb-server nginx redis-server

systemctl enable --now php8.3-fpm

# Instalar Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

echo -e "${AZUL}[*] Descargando Panel...${NC}"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

echo -e "${AZUL}[*] Configurando MariaDB...${NC}"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
mysql -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${PASS_DB}';"
mysql -u root -e "ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${PASS_DB}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
mysql -u root -e "FLUSH PRIVILEGES;"

echo -e "${AZUL}[*] Ejecutando instalador interno (Artisan)...${NC}"
cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup --author="$EMAIL_ADMIN" --url="$URL_PANEL" --timezone="America/Mexico_City" --cache="redis" --session="database" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui="yes" --telemetry="no"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="${PASS_DB}"
php artisan migrate --seed --force

echo -e "${AZUL}[*] Creando cuenta de administrador...${NC}"
php artisan p:user:make --email="$EMAIL_ADMIN" --username="admin" --name-first="Admin" --name-last="User" --password="${PASS_ADMIN}" --admin=1

chown -R www-data:www-data /var/www/pterodactyl/*

crontab -l 2>/dev/null | grep -v "/var/www/pterodactyl/artisan schedule:run" | { cat; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"; } | crontab -

cat <<EOF > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pteroq.service
systemctl enable --now redis-server

echo -e "${AZUL}[*] Aplicando archivos de configuración a Nginx...${NC}"
rm -f /etc/nginx/sites-enabled/default

if [[ "$USAR_SSL" == "y" ]]; then
    systemctl stop nginx
    certbot certonly --standalone -d "$DOMINIO_NGINX" --agree-tos --email "$EMAIL_ADMIN" --non-interactive
    
    cat <<EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name $DOMINIO_NGINX;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMINIO_NGINX;
    root /var/www/pterodactyl/public;
    index index.php;
    client_max_body_size 100m;
    ssl_certificate /etc/letsencrypt/live/$DOMINIO_NGINX/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMINIO_NGINX/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
else
    cat <<EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name $DOMINIO_NGINX;
    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
fi

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

echo "$DOMINIO_NGINX" > /tmp/ptero_domain
echo "$IP_DETECTADA" > /tmp/ptero_ip

echo "--- CREDENCIALES PANEL PTERODACTYL ---" > ~/credenciales_pterodactyl.txt
echo "URL del Panel: $URL_PANEL" >> ~/credenciales_pterodactyl.txt
echo "Usuario de acceso: admin" >> ~/credenciales_pterodactyl.txt
echo "Email Administrador: $EMAIL_ADMIN" >> ~/credenciales_pterodactyl.txt
echo "Contraseña Administrador: $PASS_ADMIN" >> ~/credenciales_pterodactyl.txt

echo -e "\n${VERDE}==================================================${NC}"
echo -e "${VERDE}      FIN DEL SCRIPT DE INSTALACIÓN DEL PANEL    ${NC}"
echo -e "${VERDE}==================================================${NC}"
cat ~/credenciales_pterodactyl.txt
echo -e "${VERDE}==================================================${NC}"
echo -e "${AZUL}Si ves algún error arriba, haz scroll en tu consola para revisarlo.${NC}\n"
