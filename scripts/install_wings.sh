#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

echo -e "${AZUL}=== INSTALACIÓN DE WINGS ===${NC}"

# Instalación de Docker (Requisito universal para Wings)
if ! command -v docker &> /dev/null; then
    echo -e "${AZUL}[*] Instalando Docker...${NC}"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
fi

mkdir -p /etc/pterodactyl /var/log/pterodactyl

echo "Selecciona el método de configuración del nodo:"
echo "1) Obtener configuración automáticamente por API (Recomendado para Remoto)"
echo "2) Pegar comando de configuración manualmente"
read -p "Opción [1-2]: " metodo_wings

if [ "$metodo_wings" == "1" ]; then
    read -p "URL del Panel (ej. http://192.168.1.50): " PANEL_URL
    read -p "Token API de Administrador: " API_TOKEN
    read -p "ID del Nodo: " NODO_ID
    PANEL_URL="${PANEL_URL%/}"

    echo -e "${AZUL}[*] Descargando configuración...${NC}"
    RESPONSE=$(curl -s -w "%{http_code}" -o /etc/pterodactyl/config.yml \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      "$PANEL_URL/api/application/nodes/$NODO_ID/configuration")

    if [ "$RESPONSE" -ne 200 ]; then
        echo -e "${ROJO}[!] Error al conectar con la API (Código: $RESPONSE).${NC}"
        exit 1
    fi
else
    read -p "Pega aquí el token completo de configuración sudo wings... : " COMANDO_MANUAL
    eval "$COMANDO_MANUAL"
fi

echo -e "${AZUL}[*] Instalando Wings...${NC}"
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod +x /usr/local/bin/wings

# Crear servicio
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
echo -e "${VERDE}[+] ¡Wings instalado y corriendo!${NC}"
