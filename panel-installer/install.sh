#!/bin/bash

# Colores para la consola
VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m' # Sin color

# Validar que se ejecute como root
if [ "$EUID" -ne 0 ]; then
  echo -e "${ROJO}[!] Por favor, ejecuta este script como root (sudo).${NC}"
  exit 1
fi

# Función para mostrar el resumen de instalación
mostrar_resumen() {
    clear
    echo -e "${VERDE}==================================================${NC}"
    echo -e "${VERDE}      INSTALACIÓN COMPLETADA EXITOSAMENTE        ${NC}"
    echo -e "${VERDE}==================================================${NC}"
    if [ -f "~/credenciales_pterodactyl.txt" ]; then
        cat ~/credenciales_pterodactyl.txt
    else
        echo "Las credenciales han sido guardadas en tu panel."
    fi
    echo -e "${VERDE}==================================================${NC}"
}

# Funciones de Instalación
instalar_panel() {
    echo -e "${AZUL}[*] Iniciando instalación del Panel Pterodactyl...${NC}"
    # Aquí irá tu lógica de instalación de dependencias, Nginx, MariaDB y Pterodactyl.
    
    # Ejemplo de cómo guardar credenciales creadas:
    echo "--- CREDENCIALES PANEL PTERODACTYL ---" > ~/credenciales_pterodactyl.txt
    echo "URL del Panel: http://$(hostname -I | awk '{print $1}')" >> ~/credenciales_pterodactyl.txt
    echo "Usuario Admin: admin@ejemplo.com" >> ~/credenciales_pterodactyl.txt
    echo "Contraseña DB: $(openssl rand -base64 12)" >> ~/credenciales_pterodactyl.txt
    
    mostrar_resumen
}

instalar_wings_local() {
    echo -e "${AZUL}[*] Instalando Wings en esta misma máquina...${NC}"
    # Lógica para instalar Docker y Wings localmente
}

instalar_wings_remoto() {
    echo -e "${AZUL}[*] Configurando Wings Remoto...${NC}"
    read -p "Introduce la URL de tu Panel (ej. http://192.168.1.50): " PANEL_URL
    read -p "Introduce el Token API de Administrador: " API_TOKEN
    read -p "Introduce el ID del Nodo: " NODO_ID
    
    echo -e "${AZUL}[*] Descargando configuración del nodo desde el panel...${NC}"
    # Comando para descargar el config.yml usando la API
    # curl -H "Authorization: Bearer $API_TOKEN" -H "Accept: application/json" "$PANEL_URL/api/application/nodes/$NODO_ID/configuration"
}

# Función de Respaldos
crear_respaldo() {
    clear
    echo -e "${AZUL}=== MENÚ DE RESPALDOS ===${NC}"
    echo "1) Respaldar Solo Panel"
    echo "2) Respaldar Panel + Wings (Sin servidores de juegos)"
    read -p "Selecciona una opción: " opcion_backup

    FECHA=$(date +%F_%H-%M-%S)
    RUTA_ZIP="/tmp/pterodactyl_backup_$FECHA.zip"
    
    # Carpeta temporal para juntar archivos antes del zip
    mkdir -p /tmp/pterodactyl_backup_datos
    
    if [ "$opcion_backup" == "1" ] || [ "$opcion_backup" == "2" ]; then
        echo -e "${AZUL}[*] Exportando Base de Datos...${NC}"
        # mysqldump -u root -p pterodactyl > /tmp/pterodactyl_backup_datos/db.sql
        
        echo -e "${AZUL}[*] Copiando archivos de configuración del Panel...${NC}"
        # cp /var/www/pterodactyl/.env /tmp/pterodactyl_backup_datos/
        
        if [ "$opcion_backup" == "2" ]; then
            echo -e "${AZUL}[*] Copiando configuración de Wings...${NC}"
            # cp /etc/pterodactyl/config.yml /tmp/pterodactyl_backup_datos/
        fi
        
        # Comprimir todo en el ZIP
        echo -e "${AZUL}[*] Creando archivo ZIP...${NC}"
        zip -r "$RUTA_ZIP" /tmp/pterodactyl_backup_datos > /dev/null
        
        # Subir al servidor temporal
        echo -e "${VERDE}[*] Subiendo respaldo a servidor temporal (bashupload.com)...${NC}"
        ENLACE=$(curl -s --upload-file "$RUTA_ZIP" "https://bashupload.com/backup_$FECHA.zip")
        
        clear
        echo -e "${VERDE}==================================================${NC}"
        echo -e "${VERDE}               RESPALDO COMPLETADO                ${NC}"
        echo -e "${VERDE}==================================================${NC}"
        echo -e "Tu archivo local está en: $RUTA_ZIP"
        echo -e "Descárgalo en otra máquina con el siguiente enlace:"
        echo -e "${AZUL}$ENLACE${NC}"
        echo -e "Nota: El enlace expirará automáticamente en 3 días."
        echo -e "${VERDE}==================================================${NC}"
        
        # Limpieza
        rm -rf /tmp/pterodactyl_backup_datos
    else
        echo -e "${ROJO}Opción inválida.${NC}"
    fi
}

# Menú Principal
while true; do
    echo -e "${AZUL}==================================================${NC}"
    echo -e "${AZUL}     HERRAMIENTA DE AUTOMATIZACIÓN PTERODACTYL    ${NC}"
    echo -e "${AZUL}==================================================${NC}"
    echo "1) Instalar Panel Pterodactyl"
    echo "2) Instalar Wings (Local)"
    echo "3) Instalar Wings (Remoto)"
    echo "4) Crear y Subir Respaldo"
    echo "5) Salir"
    echo -e "${AZUL}==================================================${NC}"
    read -p "Selecciona una opción [1-5]: " opcion

    case $opcion in
        1) instalar_panel ;;
        2) instalar_wings_local ;;
        3) instalar_wings_remoto ;;
        4) crear_respaldo ;;
        5) echo -e "${VERDE}¡Hasta luego!${NC}"; exit 0 ;;
        *) echo -e "${ROJO}[!] Opción no válida. Intenta de nuevo.${NC}" ;;
    esac
    echo ""
    read -p "Presiona Enter para continuar..."
    clear
done
