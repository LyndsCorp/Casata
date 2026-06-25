#!/bin/bash
# /usr/local/casata/modules/search.sh

DATA_DIR="/usr/local/casata/data"

# Colores (ajústalos según tus definiciones)
YELLOW="\e[33m"
GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

# --------------------------------------------------
# Función para listar todos los paquetes
# --------------------------------------------------
list_all() {
    if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        echo "La base de datos local está vacía. Ejecuta 'casata update' primero."
        exit 0
    fi
    for DB_FILE in "$DATA_DIR"/*.json; do
        PKG_NAME=$(jq -r '.name' "$DB_FILE")
        PKG_DESC=$(jq -r '.description // "Sin descripción"' "$DB_FILE")
        echo -e "${GREEN}$PKG_NAME${NC} - $PKG_DESC"
    done
}

# --------------------------------------------------
# Sin argumentos -> listar todo
# --------------------------------------------------
if [ $# -eq 0 ]; then
    list_all
    exit 0
fi

# --------------------------------------------------
# Detección de expansión accidental del glob
# --------------------------------------------------
# Si hay más de un argumento, o el único argumento existe como fichero/directorio
# en el directorio actual, asumimos que fue un metacarácter expandido.
if [ $# -gt 1 ] || [ $# -eq 1 -a -e "$1" ]; then
    list_all
    exit 0
fi

# --------------------------------------------------
# Procesamiento normal del argumento (no expandido)
# --------------------------------------------------
TEXTO="$1"
texto_lower="${TEXTO,,}"

echo -e "${YELLOW}Resultados de búsqueda para:${NC} $TEXTO\n"
FOUND=0

if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo "La base de datos local está vacía. Ejecuta 'casata update' primero."
    exit 0
fi

# Detectar si el texto contiene metacaracteres glob (*, ?, [)
if [[ "$texto_lower" == *[*?[]* ]]; then
    # MODO PATRÓN GLOB
    for DB_FILE in "$DATA_DIR"/*.json; do
        pkg_name=$(jq -r '.name' "$DB_FILE")
        pkg_desc=$(jq -r '.description // "Sin descripción"' "$DB_FILE")
        name_lower="${pkg_name,,}"
        desc_lower="${pkg_desc,,}"

        if [[ "$name_lower" == $texto_lower ]] || [[ "$desc_lower" == $texto_lower ]]; then
            echo -e "${GREEN}$pkg_name${NC} - $pkg_desc"
            FOUND=$((FOUND + 1))
        fi
    done
else
    # MODO SUBCADENA (búsqueda original)
    for DB_FILE in "$DATA_DIR"/*.json; do
        pkg_name=$(jq -r '.name' "$DB_FILE")
        pkg_desc=$(jq -r '.description // "Sin descripción"' "$DB_FILE")

        if [[ "${pkg_name,,}" == *"$texto_lower"* ]] || [[ "${pkg_desc,,}" == *"$texto_lower"* ]]; then
            echo -e "${GREEN}$pkg_name${NC} - $pkg_desc"
            FOUND=$((FOUND + 1))
        fi
    done
fi

if [ $FOUND -eq 0 ]; then
    echo -e "${RED}No se encontraron paquetes que coincidan con '${TEXTO}'.${NC}"
fi
