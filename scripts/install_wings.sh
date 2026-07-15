#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}=== INSTALACIÓN REAL DE WINGS ===${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${AZUL}[*] Instalando entorno de Docker...${NC}"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
fi

read -p "¿Deseas generar certificados SSL (Let's Encrypt) para este Nodo? (y/n): " SSL_WINGS
if [[ "$SSL_WINGS" == "y" ]]; then
    read -p "Introduce el dominio único asignado a este Nodo (ej. nodo1.tudominio.com): " DOMINIO_WINGS
    read -p "Introduce tu correo electrónico: " CORREO_WINGS
    apt install -y certbot
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone -d "$DOMINIO_WINGS" --agree-tos --email "$CORREO_WINGS" --non-interactive
    systemctl start nginx 2>/dev/null
fi

mkdir -p /etc/pterodactyl /var/log/pterodactyl

echo "Selecciona el método de configuración del nodo:"
echo "1) Obtener configuración automáticamente por API (Recomendado)"
echo "2) Pegar comando de configuración manualmente"
read -p "Opción [1-2]: " metodo_wings

if [ "$metodo_wings" == "1" ]; then
    read -p "URL completa del Panel (ej. http://192.168.64.2 o https://panel.tudominio.com): " PANEL_URL
    read -p "Token API de la aplicación (Application API Key): " API_TOKEN
    read -p "ID numérico del Nodo (ej. 1): " NODO_ID
    PANEL_URL="${PANEL_URL%/}"

    echo -e "${AZUL}[*] Conectando con la API del panel para volcar config.yml...${NC}"
    RESPONSE=$(curl -s -w "%{http_code}" -o /etc/pterodactyl/config.yml \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      "$PANEL_URL/api/application/nodes/$NODO_ID/configuration")

    if [ "$RESPONSE" -ne 200 ]; then
        echo -e "${ROJO}[!] No se pudo estructurar el archivo. Código HTTP API: $RESPONSE.${NC}"
        exit 1
    fi
else
    read -p "Pega el comando 'sudo wings configure...' completo: " COMANDO_MANUAL
    eval "$COMANDO_MANUAL"
fi

echo -e "${AZUL}[*] Descargando y desplegando binario de Wings...${NC}"
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod +x /usr/local/bin/wings

cat <<EOF > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PidFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings
echo -e "${VERDE}[+] Demonio Wings corriendo de manera activa en el sistema.${NC}"
