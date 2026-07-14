#!/bin/bash

VERDE='\033[0;32m'
AZUL='\033[0;34m'
NC='\033[0m'

echo -e "${AZUL}[*] Iniciando instalación del Panel Pterodactyl...${NC}"

# 1. Actualizar sistema e instalar dependencias básicas
apt update -y && apt upgrade -y
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

# (Aquí añadirías los comandos oficiales de Pterodactyl para instalar PHP, MariaDB, Nginx, Redis y Composer)
echo -e "${AZUL}[*] Simulando instalación de dependencias y panel...${NC}"
sleep 2 # Simulación de tiempo

# 2. Generación de credenciales (Este archivo se le entrega al usuario al final)
PASS_DB=$(openssl rand -base64 16)
PASS_ADMIN=$(openssl rand -base64 12)
IP_PUBLICA=$(curl -s ifconfig.me)

echo "--- CREDENCIALES PANEL PTERODACTYL ---" > ~/credenciales_pterodactyl.txt
echo "URL del Panel: http://$IP_PUBLICA" >> ~/credenciales_pterodactyl.txt
echo "Base de Datos: pterodactyl" >> ~/credenciales_pterodactyl.txt
echo "Usuario DB: pterodactyluser" >> ~/credenciales_pterodactyl.txt
echo "Contraseña DB: $PASS_DB" >> ~/credenciales_pterodactyl.txt
echo "Usuario Admin Panel: admin@tudominio.com" >> ~/credenciales_pterodactyl.txt
echo "Contraseña Admin: $PASS_ADMIN" >> ~/credenciales_pterodactyl.txt

clear
echo -e "${VERDE}==================================================${NC}"
echo -e "${VERDE}      INSTALACIÓN COMPLETADA EXITOSAMENTE        ${NC}"
echo -e "${VERDE}==================================================${NC}"
cat ~/credenciales_pterodactyl.txt
echo -e "${VERDE}==================================================${NC}"
echo -e "Estas credenciales han sido guardadas en: ~/credenciales_pterodactyl.txt"
