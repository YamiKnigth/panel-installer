#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}[*] Iniciando instalación oficial del Panel Pterodactyl...${NC}"

# 1. Detectar la IP interna real de la máquina virtual (Evita capturar la WAN del módem)
IP_DETECTADA=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

# Generación automática de contraseñas seguras
PASS_DB=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
PASS_ADMIN=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')

# 2. Preguntas Interactivas
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

echo -e "${AZUL}[*] Actualizando sistema e instalando dependencias base...${NC}"
apt update -y && apt upgrade -y
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg certbot python3-certbot-nginx zip unzip tar git

# Añadir repositorios oficiales para PHP 8.3, Redis y MariaDB
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
curl -fsSL https://packages.redis.io/gpg | gpg --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash

apt update -y
echo -e "${AZUL}[*] Instalando Nginx, MariaDB, Redis y PHP 8.3...${NC}"
apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx redis-server

# Instalar Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Descargar archivos oficiales de Pterodactyl
echo -e "${AZUL}[*] Descargando Panel...${NC}"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Configurar Base de Datos MariaDB
echo -e "${AZUL}[*] Configurando MariaDB...${NC}"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
mysql -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${PASS_DB}';"
mysql -u root -e "ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${PASS_DB}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
mysql -u root -e "FLUSH PRIVILEGES;"

# Configuración del Entorno de Pterodactyl
echo -e "${AZUL}[*] Ejecutando instalador interno (Artisan)...${NC}"
cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Configurar archivo de entorno sin interacción
php artisan p:environment:setup --author="$EMAIL_ADMIN" --url="$URL_PANEL" --timezone="America/Mexico_City" --cache="redis" --session="database" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui="yes" --telemetry="no"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="${PASS_DB}"
php artisan migrate --seed --force

# Crear usuario Administrador inicial
echo -e "${AZUL}[*] Creando cuenta de administrador...${NC}"
php artisan p:user:make --email="$EMAIL_ADMIN" --username="admin" --name-first="Admin" --name-last="User" --password="${PASS_ADMIN}" --admin=1

# Permisos finales de directorios
chown -R www-data:www-data /var/www/pterodactyl/*

# Configurar Cron y cola de trabajos (Queue Worker)
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

systemctl enable --now pteroq.service
systemctl enable --now redis-server

# Configuración del Servidor Web Nginx
echo -e "${AZUL}[*] Aplicando archivos de configuración a Nginx...${NC}"
rm -f /etc
