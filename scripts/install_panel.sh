#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
NC='\033[0m'
ROJO='\033[0;31m'

echo -e "${AZUL}[*] Iniciando instalación real del Panel Pterodactyl...${NC}"

# Variables Generadas
PASS_DB=$(openssl rand -base64 16)
PASS_ADMIN=$(openssl rand -base64 12)
IP_PUBLICA=$(curl -s ifconfig.me)

# Preguntas Interactivas
read -p "Introduce un correo para el Administrador del panel: " EMAIL_ADMIN
read -p "¿Deseas instalar un certificado SSL gratuito (HTTPS)? Requiere un dominio previamente apuntado a esta IP. (y/n): " USAR_SSL

if [[ "$USAR_SSL" == "y" ]]; then
    read -p "Introduce tu dominio (ej. panel.tudominio.com): " DOMINIO
    URL_PANEL="https://$DOMINIO"
    DOMINIO_NGINX="$DOMINIO"
else
    DOMINIO=""
    URL_PANEL="http://$IP_PUBLICA"
    DOMINIO_NGINX="$IP_PUBLICA"
fi

echo -e "${AZUL}[*] Actualizando sistema e instalando dependencias base...${NC}"
apt update -y && apt upgrade -y
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg certbot python3-certbot-nginx

# Añadir repositorios oficiales para PHP 8.3, Redis y MariaDB
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
curl -fsSL https://packages.redis.io/gpg | gpg --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash

apt update -y
echo -e "${AZUL}[*] Instalando Nginx, MariaDB, Redis y PHP 8.3...${NC}"
apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Instalar Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Descargar archivos de Pterodactyl
echo -e "${AZUL}[*] Descargando Panel Pterodactyl...${NC}"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Configurar Base de Datos
echo -e "${AZUL}[*] Configurando Base de Datos MariaDB...${NC}"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
mysql -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${PASS_DB}';"
mysql -u root -e "ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${PASS_DB}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
mysql -u root -e "FLUSH PRIVILEGES;"

# Configuración del Entorno de Pterodactyl (Automático mediante Artisan)
echo -e "${AZUL}[*] Configurando entorno y claves...${NC}"
cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Autocompletado del entorno sin interacción
php artisan p:environment:setup --author="$EMAIL_ADMIN" --url="$URL_PANEL" --timezone="America/Mexico_City" --cache="redis" --session="database" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui="yes" --telemetry="no"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="${PASS_DB}"
php artisan migrate --seed --force

echo -e "${AZUL}[*] Creando usuario administrador...${NC}"
php artisan p:user:make --email="$EMAIL_ADMIN" --username="admin" --name-first="Admin" --name-last="User" --password="${PASS_ADMIN}" --admin=1

# Permisos
chown -R www-data:www-data /var/www/pterodactyl/*

# Cron y Worker
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

# Configuración Nginx y SSL
echo -e "${AZUL}[*] Configurando Nginx Web Server...${NC}"
rm -f /etc/nginx/sites-enabled/default

if [[ "$USAR_SSL" == "y" ]]; then
    systemctl stop nginx
    certbot certonly --standalone -d "$DOMINIO" --agree-tos --email "$EMAIL_ADMIN" --non-interactive
    
    # Plantilla NGINX con HTTPS (Recomendada por Pterodactyl)
    cat <<EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name $DOMINIO;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMINIO;
    root /var/www/pterodactyl/public;
    index index.php;
    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    ssl_certificate /etc/letsencrypt/live/$DOMINIO/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMINIO/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
else
    # Plantilla NGINX estándar HTTP
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
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
fi

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

# Generación de Resumen de Credenciales
echo "--- CREDENCIALES PANEL PTERODACTYL ---" > ~/credenciales_pterodactyl.txt
echo "URL del Panel: $URL_PANEL" >> ~/credenciales_pterodactyl.txt
echo "Base de Datos: panel" >> ~/credenciales_pterodactyl.txt
echo "Usuario DB: pterodactyl" >> ~/credenciales_pterodactyl.txt
echo "Contraseña DB: $PASS_DB" >> ~/credenciales_pterodactyl.txt
echo "Usuario Admin Panel: admin" >> ~/credenciales_pterodactyl.txt
echo "Email Admin: $EMAIL_ADMIN" >> ~/credenciales_pterodactyl.txt
echo "Contraseña Admin: $PASS_ADMIN" >> ~/credenciales_pterodactyl.txt

clear
echo -e "${VERDE}==================================================${NC}"
echo -e "${VERDE}      INSTALACIÓN COMPLETADA EXITOSAMENTE        ${NC}"
echo -e "${VERDE}==================================================${NC}"
cat ~/credenciales_pterodactyl.txt
echo -e "${VERDE}==================================================${NC}"
echo -e "Estas credenciales han sido guardadas en: ~/credenciales_pterodactyl.txt"
