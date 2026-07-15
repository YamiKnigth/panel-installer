#!/bin/bash

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
