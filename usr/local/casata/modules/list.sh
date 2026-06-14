#!/bin/bash
# /usr/local/casata/modules/list.sh - Lista de aplicaciones

shopt -s nullglob

CASATA_ROOT="/usr/local/casata"
DATA_DIR="$CASATA_ROOT/data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Valores por defecto
SHOW_VERSION=0
SHOW_DESC=0

# Usar getopts para procesar opciones (soporta agrupación: -vd)
while getopts "vd" opt; do
    case "$opt" in
        v) SHOW_VERSION=1 ;;
        d) SHOW_DESC=1 ;;
        *)
            echo -e "${RED}Uso: casata list [-v] [-d]${NC}"
            exit 1
            ;;
    esac
done

# Verificar que existan datos
if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}No hay aplicaciones indexadas. Ejecuta 'casata update' primero.${NC}"
    exit 0
fi

# Mostrar cabecera según opciones
if [ $SHOW_VERSION -eq 1 ] && [ $SHOW_DESC -eq 1 ]; then
    printf "${GREEN}%-30s %-15s %s${NC}\n" "NOMBRE" "VERSIÓN" "DESCRIPCIÓN"
    echo "----------------------------------------------------------------------"
elif [ $SHOW_VERSION -eq 1 ]; then
    printf "${GREEN}%-30s %-15s${NC}\n" "NOMBRE" "VERSIÓN"
    echo "----------------------------------------------"
elif [ $SHOW_DESC -eq 1 ]; then
    printf "${GREEN}%-30s %s${NC}\n" "NOMBRE" "DESCRIPCIÓN"
    echo "--------------------------------------------------------------"
else
    echo -e "${GREEN}Aplicaciones disponibles:${NC}"
fi

# Listar aplicaciones
for DB_FILE in "$DATA_DIR"/*.json; do
    [ -f "$DB_FILE" ] || continue
    NAME=$(jq -r '.name // "sin_nombre"' "$DB_FILE")
    VERSION=$(jq -r '.version // "desconocida"' "$DB_FILE")
    DESC=$(jq -r '.description // ""' "$DB_FILE")

    if [ $SHOW_VERSION -eq 1 ] && [ $SHOW_DESC -eq 1 ]; then
        printf "%-30s %-15s %s\n" "$NAME" "$VERSION" "$DESC"
    elif [ $SHOW_VERSION -eq 1 ]; then
        printf "%-30s %-15s\n" "$NAME" "$VERSION"
    elif [ $SHOW_DESC -eq 1 ]; then
        printf "%-30s %s\n" "$NAME" "$DESC"
    else
        echo "  $NAME"
    fi
done

# Contador total
TOTAL=$(ls -1 "$DATA_DIR"/*.json 2>/dev/null | wc -l)
echo -e "\n${YELLOW}Total: $TOTAL aplicaciones disponibles.${NC}"
