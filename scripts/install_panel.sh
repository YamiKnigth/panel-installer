#!/bin/bash

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

# Exportar variables temporales para que el script de Wings las use de inmediato
echo "$DOMINIO_NGINX" > /tmp/ptero_domain
echo "$IP_DETECTADA" > /tmp/ptero_ip

echo "--- CREDENCIALES PANEL PTERODACTYL ---" > ~/credenciales_pterodactyl.txt
echo "URL del Panel: $URL_PANEL" >> ~/credenciales_pterodactyl.txt
echo "Usuario de acceso: admin" >> ~/credenciales_pterodactyl.txt
echo "Email Administrador: $EMAIL_ADMIN" >> ~/credenciales_pterodactyl.txt
echo "Contraseña Administrador: $PASS_ADMIN" >> ~/credenciales_pterodactyl.txt

clear
echo -e "${VERDE}==================================================${NC}"
echo -e "${VERDE}      PANEL INSTALADO - PROCEDIENDO A WINGS${NC}"
echo -e "${VERDE}==================================================${NC}"
