#!/bin/bash
# /usr/local/casata/modules/show.sh
# Muestra información técnica de las aplicaciones instaladas globalmente
# incluyendo tamaño en disco y tamaño declarado en metadatos.

shopt -s nullglob

CASATA_ROOT="/usr/local/casata"
SYS_DIR="$CASATA_ROOT/apps"
DATA_DIR="$CASATA_ROOT/data"

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

    # Tamaño en disco (tamaño lógico)
    if [ -d "$app_dir" ]; then
        size_disk=$(du -sh "$app_dir" 2>/dev/null | cut -f1)
        echo -e "  ${YELLOW}Tamaño en disco:${NC} $size_disk"
    else
        echo -e "  ${YELLOW}Tamaño en disco:${NC} (no disponible)"
    fi

    # Tamaño según metadatos
    local meta_file="$DATA_DIR/${pkg_name}.json"
    if [ -f "$meta_file" ]; then
        size_meta=$(jq -r '.size // ""' "$meta_file" 2>/dev/null)
        if [ -n "$size_meta" ]; then
            echo -e "  ${YELLOW}Tamaño según metadatos:${NC} $size_meta"
        else
            echo -e "  ${YELLOW}Tamaño según metadatos:${NC} (no especificado)"
        fi
    else
        echo -e "  ${YELLOW}Tamaño según metadatos:${NC} (no hay metadatos)"
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
        jq -c '.links[]' "$guide_file" 2>/dev/null | while read -r item; do
            dest=$(echo "$item" | jq -r '.dest // ""')
            name=$(echo "$item" | jq -r '.name // ""')
            if [ -n "$dest" ] && [ -n "$name" ]; then
                dest_expanded="${dest/#\~/$HOME}"
                dest_expanded="${dest_expanded//\$HOME/$HOME}"
                echo -e "    → $name ${GREEN}->${NC} $dest_expanded"
            fi
        done
    else
        echo -e "  ${YELLOW}Enlaces simbólicos:${NC} (no definidos)"
    fi

    # ---- Mostrar metadatos del repositorio si existen ----
    if [ -f "$meta_file" ]; then
        echo -e "  ${YELLOW}Metadatos del repositorio:${NC}"
        local is_open=$(jq -r '.is_open_sorce // false' "$meta_file" 2>/dev/null)
        local source_code=$(jq -r '.source_code // ""' "$meta_file" 2>/dev/null)
        local license=$(jq -r '.license // ""' "$meta_file" 2>/dev/null)
        local origin=$(jq -r '.origin // ""' "$meta_file" 2>/dev/null)
        local developer=$(jq -r '.developer // ""' "$meta_file" 2>/dev/null)
        local copyright_title=$(jq -r '.copyright_title // ""' "$meta_file" 2>/dev/null)
        local copyright_year=$(jq -r '.copyright_year // ""' "$meta_file" 2>/dev/null)

        [ -n "$license" ] && echo -e "    Licencia: $license" || echo -e "    Licencia: ${YELLOW}(no especificada)${NC}"

        if [ "$is_open" = "true" ] || [ "$is_open" = "1" ]; then
            [ -n "$source_code" ] && echo -e "    Código fuente: $source_code" || echo -e "    Código fuente: ${YELLOW}(no especificado)${NC}"
        else
            echo -e "    Código fuente: ${RED}No es de código abierto${NC}"
        fi

        [ -n "$origin" ] && echo -e "    Origen: $origin" || echo -e "    Origen: ${YELLOW}(no especificado)${NC}"
        [ -n "$developer" ] && echo -e "    Desarrollador: $developer" || echo -e "    Desarrollador: ${YELLOW}(no especificado)${NC}"

        if [ -n "$copyright_title" ] && [ -n "$copyright_year" ]; then
            echo -e "    Copyright: $copyright_year $copyright_title"
        elif [ -n "$copyright_title" ]; then
            echo -e "    Copyright: $copyright_title (año no especificado)"
        elif [ -n "$copyright_year" ]; then
            echo -e "    Copyright: $copyright_year (titular no especificado)"
        else
            echo -e "    Copyright: ${YELLOW}(no especificado)${NC}"
        fi

        # Advertencia de metadatos faltantes (solo si es un paquete instalado)
        local missing=()
        [ -z "$license" ] && missing+=("license")
        [ -z "$origin" ] && missing+=("origin")
        [ -z "$developer" ] && missing+=("developer")
        [ -z "$copyright_title" ] && missing+=("copyright_title")
        [ -z "$copyright_year" ] && missing+=("copyright_year")
        if [ "$is_open" = "true" ] && [ -z "$source_code" ]; then
            missing+=("source_code")
        fi
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
