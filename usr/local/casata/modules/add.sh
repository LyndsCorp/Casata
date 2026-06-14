#!/bin/bash
# /usr/local/casata/modules/add.sh - Versión estable con manejo correcto de oficial

shopt -s nullglob
set -euo pipefail

TYPE="${1:-}"
URL="${2:-}"

CASATA_ROOT="/usr/local/casata"
METAREPOS_DIR="$CASATA_ROOT/repos/metarepos"
SINGREPOS_DIR="$CASATA_ROOT/repos/singrepos"
DATA_DIR="$CASATA_ROOT/data"
OFICIAL_FILE="$CASATA_ROOT/repos/OFICIAL"   # archivo que contiene la URL del índice oficial

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Crear directorios necesarios
mkdir -p "$METAREPOS_DIR" "$SINGREPOS_DIR" "$DATA_DIR"

# --- LIMPIEZA DE TEMPORALES ---
TEMP_FILE=""
cleanup() {
    if [ -n "${TEMP_FILE:-}" ] && [ -f "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
    fi
}
trap cleanup EXIT

# --- VALIDAR HERRAMIENTAS ---
if ! command -v jq &> /dev/null || ! command -v wget &> /dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}"
    exit 1
fi

# --- FUNCIÓN: PROCESAR SINGREPO ---
process_singrepo() {
    local url="$1"
    local temp_sing=$(mktemp)
    TEMP_FILE="$temp_sing"

    echo -e "     ${YELLOW}Descargando singrepo...${NC}"
    if wget -q --timeout=30 --tries=2 -O "$temp_sing" "$url"; then
        local pkg_name=$(jq -r '.name // empty' "$temp_sing")
        local data_url=$(jq -r '.data_url // empty' "$temp_sing")

        if [ -n "$pkg_name" ] && [ -n "$data_url" ]; then
            mv "$temp_sing" "$SINGREPOS_DIR/${pkg_name}.json"
            TEMP_FILE=""
            echo -ne "     ${GREEN}[+] Registrado singrepo: ${pkg_name}${NC} ... "

            if wget -q --timeout=30 --tries=2 -O "$DATA_DIR/${pkg_name}.json" "$data_url"; then
                echo -e "${GREEN}OK (datos descargados)${NC}"
            else
                echo -e "${RED}FALLO al descargar datos${NC}"
            fi
        else
            echo -e "     ${RED}[!] JSON inválido (falta name o data_url) en $url${NC}"
        fi
    else
        echo -e "     ${RED}[!] Error de red al descargar singrepo: $url${NC}"
    fi
}

# --- FUNCIÓN: PROCESAR METAREPO ---
process_metarepo() {
    local url="$1"
    local temp_meta=$(mktemp)
    TEMP_FILE="$temp_meta"

    echo -e "${YELLOW}Procesando metarepo desde: $url${NC}"
    if ! wget -q --timeout=30 --tries=2 -O "$temp_meta" "$url"; then
        echo -e "   ${RED}[!] Error de red al descargar metarepo.${NC}"
        return 1
    fi

    # Validar JSON
    if ! jq empty "$temp_meta" 2>/dev/null; then
        echo -e "   ${RED}[!] El archivo descargado no es un JSON válido.${NC}"
        return 1
    fi

    local repo_name=$(jq -r '.name // empty' "$temp_meta")
    if [ -z "$repo_name" ]; then
        echo -e "   ${RED}[!] El metarepo no tiene campo 'name'.${NC}"
        return 1
    fi

    # Guardar metarepo en repos/metarepos/
    local target_file="$METAREPOS_DIR/${repo_name}.json"
    mv "$temp_meta" "$target_file"
    TEMP_FILE=""
    echo -e "   ${GREEN}[✓] Metarepo guardado: ${repo_name}${NC}"

    # Indexar los singrepos que contiene
    echo -e "   ${YELLOW}Indexando paquetes incluidos...${NC}"
    jq -r 'to_entries[] | select(.key != "name" and .key != "metarepo") | .value' "$target_file" | while read -r singrepo_url; do
        if [[ "$singrepo_url" == http* ]]; then
            process_singrepo "$singrepo_url"
        fi
    done
}

# --- MODO: AÑADIR SINGREPO DIRECTO ---
if [ "$TYPE" == "singrepo" ]; then
    if [ -z "$URL" ]; then
        echo -e "${RED}Error: Falta la URL del singrepo.${NC}"
        exit 1
    fi
    process_singrepo "$URL"
    exit 0
fi

# --- MODO: AÑADIR METAREPO DIRECTO ---
if [ "$TYPE" == "repo" ]; then
    if [ -z "$URL" ]; then
        echo -e "${RED}Error: Falta la URL del metarepo.${NC}"
        exit 1
    fi
    process_metarepo "$URL"
    exit 0
fi

# --- MODO: OFICIAL (sincronizar desde índice maestro) ---
if [ "$TYPE" == "oficial" ]; then
    if [ ! -f "$OFICIAL_FILE" ]; then
        echo -e "${RED}Error: No se encuentra el archivo $OFICIAL_FILE${NC}"
        echo -e "${YELLOW}Crea ese archivo con una URL que apunte a un JSON de lista de repositorios.${NC}"
        exit 1
    fi

    MASTER_URL=$(cat "$OFICIAL_FILE" | tr -d '[:space:]')
    if [ -z "$MASTER_URL" ]; then
        echo -e "${RED}Error: El archivo OFICIAL está vacío.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Sincronizando índice oficial desde: $MASTER_URL${NC}"
    TEMP_LIST=$(mktemp)
    TEMP_FILE="$TEMP_LIST"

    if ! wget -q --timeout=30 --tries=2 -O "$TEMP_LIST" "$MASTER_URL"; then
        echo -e "${RED}Error: No se pudo descargar el índice oficial.${NC}"
        exit 1
    fi

    # Validar que sea un array JSON
    if ! jq -e 'type == "array"' "$TEMP_LIST" >/dev/null 2>&1; then
        echo -e "${RED}Error: El índice oficial no es un array JSON.${NC}"
        exit 1
    fi

    REPO_COUNT=0
    ERRORS=0
    while read -r repo_url; do
        if [ -n "$repo_url" ]; then
            REPO_COUNT=$((REPO_COUNT + 1))
            echo -e "\n--- Procesando repositorio $REPO_COUNT ---"
            if process_metarepo "$repo_url"; then
                echo -e "   ${GREEN}Repositorio $REPO_COUNT procesado correctamente.${NC}"
            else
                ERRORS=$((ERRORS + 1))
                echo -e "   ${YELLOW}Advertencia: Falló el repositorio $REPO_COUNT. Continuando...${NC}"
            fi
        fi
    done < <(jq -r '.[]' "$TEMP_LIST")

    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}Sincronización oficial completada.${NC}"
    echo -e "Repositorios procesados: $REPO_COUNT"
    echo -e "Errores: $ERRORS"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    exit 0
fi

# --- SI LLEGA AQUÍ, TIPO NO VÁLIDO ---
echo -e "${RED}Uso: casata add <singrepo|repo|oficial> [URL]${NC}"
echo "  singrepo URL   - Agrega un singrepo individual"
echo "  repo URL       - Agrega un metarepo y todos sus singrepos"
echo "  oficial        - Sincroniza desde el índice oficial (configurado en /usr/local/casata/repos/OFICIAL)"
exit 1
