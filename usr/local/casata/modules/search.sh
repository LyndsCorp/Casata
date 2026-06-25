#!/bin/bash
# /usr/local/casata/modules/search.sh

DATA_DIR="/usr/local/casata/data"

# Colores (debes tenerlos definidos en tu entorno)
YELLOW="\e[33m"
GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

# Si no se pasan argumentos, listar todos los paquetes
if [ $# -eq 0 ]; then
    echo -e "${YELLOW}Listando todos los paquetes disponibles:${NC}\n"
    if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        echo "La base de datos local está vacía. Ejecuta 'casata update' primero."
        exit 0
    fi
    for DB_FILE in "$DATA_DIR"/*.json; do
        PKG_NAME=$(jq -r '.name' "$DB_FILE")
        PKG_DESC=$(jq -r '.description // "Sin descripción"' "$DB_FILE")
        echo -e "${GREEN}$PKG_NAME${NC} - $PKG_DESC"
    done
    exit 0
fi

# Si hay más de un argumento, es probable que el usuario escribiera un glob sin entrecomillar
if [ $# -gt 1 ]; then
    echo -e "${YELLOW}⚠️  Advertencia: Se recibieron múltiples argumentos.${NC}"
    echo "   Posiblemente usaste un metacarácter (*, ?, []) sin entrecomillar y el shell lo expandió"
    echo "   a los nombres de archivos del directorio actual."
    echo "   Para buscar con patrones glob, utiliza comillas: 'casata search \"patron\"' o escapa: 'casata search \\*'."
    echo "   Se continuará buscando con todos los argumentos recibidos como textos literales (búsqueda OR)."
    echo ""
fi

# Unir todos los argumentos como patrón único (por simplicidad, si se pasan varios)
TEXTO="$*"
texto_lower="${TEXTO,,}"

echo -e "${YELLOW}Resultados de búsqueda para:${NC} $TEXTO\n"
FOUND=0

if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo "La base de datos local está vacía. Ejecuta 'casata update' primero."
    exit 0
fi

# Detectar si el texto (que puede contener glob si fue bien pasado) tiene metacaracteres
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
    # MODO SUBCADENA (comportamiento original)
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
