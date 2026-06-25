#!/bin/bash
# /usr/local/casata/modules/search.sh

TEXTO=$1
DATA_DIR="/usr/local/casata/data"

echo -e "${YELLOW}Resultados de búsqueda para:${NC} $TEXTO\n"
FOUND=0

if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo "La base de datos local está vacía. Ejecuta 'casata update' primero."
    exit 0
fi

# Convertimos el texto a minúsculas una sola vez
texto_lower="${TEXTO,,}"

# Detectamos si contiene metacaracteres glob (*, ?, [)
if [[ "$texto_lower" == *[*?[]* ]]; then
    # MODO PATRÓN GLOB: emparejamos el nombre/descripción completos (case-insensitive)
    for DB_FILE in "$DATA_DIR"/*.json; do
        pkg_name=$(jq -r '.name' "$DB_FILE")
        pkg_desc=$(jq -r '.description // "Sin descripción"' "$DB_FILE")
        name_lower="${pkg_name,,}"
        desc_lower="${pkg_desc,,}"

        # Emparejamos con el patrón glob (sin comillas en la derecha para que sea patrón)
        if [[ "$name_lower" == $texto_lower ]] || [[ "$desc_lower" == $texto_lower ]]; then
            echo -e "${GREEN}$pkg_name${NC} - $pkg_desc"
            FOUND=$((FOUND + 1))
        fi
    done
else
    # MODO SUBCADENA: comportamiento original
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
