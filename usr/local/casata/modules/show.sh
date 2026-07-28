#!/bin/bash
# /usr/local/casata/modules/show.sh
# Muestra información técnica de las aplicaciones instaladas globalmente
# Casata 1.3.1

shopt -s nullglob

CASATA_ROOT="/usr/local/casata"
SYS_DIR="$CASATA_ROOT/apps"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Función para mostrar detalles de una app
show_app_info() {
    local app_dir="$1"
    local pkg_name=$(basename "$app_dir")

    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo -e "${GREEN}📦 $pkg_name${NC}"
    echo -e "  ${YELLOW}Ruta:${NC} $app_dir"

    # Tamaño
    if [ -d "$app_dir" ]; then
        size=$(du -sh "$app_dir" 2>/dev/null | cut -f1)
        echo -e "  ${YELLOW}Tamaño:${NC} $size"
    fi

    # Versión
    if [ -f "$app_dir/VERSION" ]; then
        version=$(cat "$app_dir/VERSION")
        echo -e "  ${YELLOW}Versión:${NC} $version"
    else
        echo -e "  ${YELLOW}Versión:${NC} (desconocida)"
    fi

    # Enlaces simbólicos desde GUIDE.json
    local guide_file="$app_dir/GUIDE.json"
    if [ -f "$guide_file" ]; then
        echo -e "  ${YELLOW}Enlaces simbólicos:${NC}"
        # Extraer cada enlace: dest y name
        jq -c '.links[]' "$guide_file" 2>/dev/null | while read -r item; do
            dest=$(echo "$item" | jq -r '.dest // ""')
            name=$(echo "$item" | jq -r '.name // ""')
            if [ -n "$dest" ] && [ -n "$name" ]; then
                # Expandir ~ y $HOME en dest
                dest_expanded="${dest/#\~/$HOME}"
                dest_expanded="${dest_expanded//\$HOME/$HOME}"
                echo -e "    → $name ${GREEN}->${NC} $dest_expanded"
            fi
        done
        # Si no hay enlaces, no mostrar nada
    else
        echo -e "  ${YELLOW}Enlaces simbólicos:${NC} (no definidos)"
    fi

    echo ""
}

# Si se pasa un argumento, mostrar solo esa app
if [ $# -eq 1 ]; then
    pkg_name="$1"
    app_dir="$SYS_DIR/$pkg_name"
    if [ -d "$app_dir" ]; then
        show_app_info "$app_dir"
    else
        echo -e "${RED}Error: La aplicación '$pkg_name' no está instalada globalmente.${NC}"
        exit 1
    fi
    exit 0
fi

# Sin argumentos: mostrar todas las apps globales
if [ ! -d "$SYS_DIR" ] || [ -z "$(ls -A "$SYS_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}No hay aplicaciones instaladas globalmente.${NC}"
    exit 0
fi

echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Aplicaciones instaladas (sistema global)${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"

count=0
for app_dir in "$SYS_DIR"/*; do
    [ -d "$app_dir" ] || continue
    show_app_info "$app_dir"
    count=$((count + 1))
done

echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Total: $count aplicación(es) instalada(s).${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
