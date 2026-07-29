#!/bin/bash

# Módulo motd para Casata
# Muestra el Mensaje del Día almacenado en CASATA_ROOT/news/
# Con sudo, descarga la última versión desde GitHub
# Casata 1.3.2

set -euo pipefail
shopt -s nullglob

CASATA_ROOT="/usr/local/casata"
NEWS_DIR="$CASATA_ROOT/news"
MOTD_URL="https://github.com/LyndsCorp/Lynds-MOTD/raw/refs/heads/main/today.txt"

# Colores (se heredan del script principal, pero nos aseguramos)
if [ -z "$GREEN" ]; then GREEN='\033[0;32m'; fi
if [ -z "$RED" ]; then RED='\033[0;31m'; fi
if [ -z "$NC" ]; then NC='\033[0m'; fi

# Normaliza una fecha a formato DD-MM-YYYY
# Acepta D-M-YYYY, DD/MM/YYYY, DD.MM.YYYY, etc.
normalize_date() {
    local input="$1"
    # Reemplazar separadores comunes por '-'
    input="${input//\//-}"
    input="${input//./-}"
    IFS='-' read -ra parts <<< "$input"
    if [ ${#parts[@]} -ne 3 ]; then
        return 1
    fi
    local day=$(printf "%02d" "${parts[0]}" 2>/dev/null)
    local month=$(printf "%02d" "${parts[1]}" 2>/dev/null)
    local year="${parts[2]}"
    if [ -z "$day" ] || [ -z "$month" ] || ! [[ "$year" =~ ^[0-9]{4}$ ]]; then
        return 1
    fi
    echo "${day}-${month}-${year}"
}

# Obtiene la fecha actual del sistema en formato DD-MM-YYYY
today=$(date +%d-%m-%Y)

# Devuelve la ruta del archivo más reciente (por fecha en el nombre) dentro de NEWS_DIR
get_latest_file() {
    local latest=""
    local latest_num=""
    if [ -d "$NEWS_DIR" ]; then
        for file in "$NEWS_DIR"/*.txt; do
            [ -e "$file" ] || continue
            local filename=$(basename "$file" .txt)
            local normalized=$(normalize_date "$filename")
            if [ -n "$normalized" ]; then
                # Convertir a YYYYMMDD para comparación numérica
                local date_num=$(echo "$normalized" | awk -F- '{print $3$2$1}')
                if [ -z "$latest_num" ] || [ "$date_num" -gt "$latest_num" ]; then
                    latest_num="$date_num"
                    latest="$file"
                fi
            fi
        done
    fi
    echo "$latest"
}

# Muestra el contenido del archivo para una fecha dada
show_motd_for_date() {
    local date_str="$1"
    local normalized=$(normalize_date "$date_str")
    if [ -z "$normalized" ]; then
        echo -e "${RED}Error: Formato de fecha inválido. Use DD-MM-YYYY o D-M-YYYY.${NC}"
        exit 1
    fi
    local file="$NEWS_DIR/${normalized}.txt"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo -e "${RED}No hay mensaje del día para la fecha ${normalized}.${NC}"
        exit 1
    fi
}

# Descarga el mensaje actual y lo guarda con la fecha de hoy (solo root)
download_today_motd() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Se requieren privilegios de root para actualizar el mensaje del día.${NC}"
        exit 1
    fi
    mkdir -p "$NEWS_DIR"
    local temp_file=$(mktemp)
    if command -v curl &> /dev/null; then
        curl -s -L -o "$temp_file" "$MOTD_URL"
    elif command -v wget &> /dev/null; then
        wget -q -O "$temp_file" "$MOTD_URL"
    else
        echo -e "${RED}Error: No se encontró curl ni wget para descargar.${NC}"
        rm -f "$temp_file"
        exit 1
    fi
    if [ ! -s "$temp_file" ]; then
        echo -e "${RED}Error: Fallo al descargar el mensaje del día.${NC}"
        rm -f "$temp_file"
        exit 1
    fi
    local dest_file="$NEWS_DIR/${today}.txt"
    mv "$temp_file" "$dest_file"
    echo -e "${GREEN}Mensaje del día actualizado a ${today}.${NC}"
    cat "$dest_file"
}

# ----------------------------------------------------------------------
# Lógica principal
# ----------------------------------------------------------------------

if [ "$EUID" -eq 0 ]; then
    # Comportamiento como root
    if [ $# -eq 0 ]; then
        # sudo casata motd  -> descarga y muestra el de hoy
        download_today_motd
    else
        # sudo casata motd <fecha> -> muestra la fecha indicada (no descarga)
        show_motd_for_date "$1"
    fi
else
    # Usuario normal
    if [ $# -eq 0 ]; then
        # Sin argumentos: mostrar el más reciente y avisar si no es hoy
        latest_file=$(get_latest_file)
        if [ -z "$latest_file" ]; then
            echo "No hay mensajes del día disponibles."
            echo -e "${RED}¡Recuerda pedirle a tu administrador que ejecute sudo casata motd!${NC}"
            exit 0
        fi
        latest_date=$(basename "$latest_file" .txt)
        cat "$latest_file"
        if [ "$latest_date" != "$today" ]; then
            echo -e "\n${RED}¡Recuerda pedirle a tu administrador que ejecute sudo casata motd!${NC}"
        fi
    else
        # Con fecha: mostrar esa fecha específica
        show_motd_for_date "$1"
    fi
fi
