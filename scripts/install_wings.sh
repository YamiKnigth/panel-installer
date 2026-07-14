#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}=== INSTALACIÓN DE WINGS ===${NC}"

# 1. Instalación de Docker
if ! command -v docker &> /dev/null; then
    echo -e "${AZUL}[*] Instalando Docker...${NC}"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
fi

# 2. Configurar SSL si lo requiere
read -p "¿Deseas crear un certificado SSL (Let's Encrypt) para este Nodo? (Recomendado) (y/n): " SSL_WINGS
if [[ "$SSL_WINGS" == "y" ]]; then
    read -p "Introduce el dominio para este Nodo (ej. nodo1.tudominio.com): " DOMINIO_WINGS
    read -p "Introduce tu correo electrónico para el SSL: " CORREO_WINGS
    apt install -y certbot
    systemctl stop nginx 2>/dev/null # Para liberar el puerto 80 temporalmente
    certbot certonly --standalone -d "$DOMINIO_WINGS" --agree-tos --email "$CORREO_WINGS" --non-interactive
    systemctl start nginx 2>/dev/null
    echo -e "${VERDE}[+] Certificados creados en /etc/letsencrypt/live/$DOMINIO_WINGS/${NC}"
fi

mkdir -p /etc/pterodactyl /var/log/pterodactyl

# 3. Vincular con Panel
echo "Selecciona el método de configuración del nodo:"
echo "1) Obtener configuración automáticamente por API (Recomendado)"
echo "2) Pegar comando de configuración manualmente (Token sudo wings...)"
read -p "Opción [1-2]: " metodo_wings

if [ "$metodo_wings" == "1" ]; then
    read -p "URL del Panel (ej. https://panel.tudominio.com): " PANEL_URL
    read -p "Token API de Administrador: " API_TOKEN
    read -p "ID del Nodo (Número entero, ej. 1): " NODO_ID
    PANEL_URL="${PANEL_URL%/}"

    echo -e "${AZUL}[*] Descargando configuración.yml desde la API...${NC}"
    RESPONSE=$(curl -s -w "%{http_code}" -o /etc/pterodactyl/config.yml \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      "$PANEL_URL/api/application/nodes/$NODO_ID/configuration")

    if [ "$RESPONSE" -ne 200 ]; then
        echo -e "${ROJO}[!] Error al conectar con la API (Código: $RESPONSE).${NC}"
        echo "Verifica que el Nodo exista y que la API Key sea válida."
        exit 1
    fi
else
    read -p "Pega aquí el comando 'sudo wings configure...' proporcionado por el panel: " COMANDO_MANUAL
    eval "$COMANDO_MANUAL"
fi

# 4. Instalar y arrancar Wings
echo -e "${AZUL}[*] Instalando Binario Wings...${NC}"
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
echo -e "${VERDE}[+] ¡Wings instalado y corriendo en segundo plano! Usa 'systemctl status wings' para comprobar.${NC}"
