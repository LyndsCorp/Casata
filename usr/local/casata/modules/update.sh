#!/bin/bash
# /usr/local/casata/modules/update.sh
# Actualiza todos los metarepos, singrepos y la base de datos local

shopt -s nullglob          # Evita bucles con "*.json" si no hay archivos
set -euo pipefail          # Modo seguro

CASATA_ROOT="/usr/local/casata"
METAREPOS_DIR="$CASATA_ROOT/repos/metarepos"
SINGREPOS_DIR="$CASATA_ROOT/repos/singrepos"
DATA_DIR="$CASATA_ROOT/data"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'          # Corregido: antes no estaba definido
NC='\033[0m'

# Crear directorios si no existen
mkdir -p "$METAREPOS_DIR" "$SINGREPOS_DIR" "$DATA_DIR"

# Archivo de bloqueo para evitar ejecuciones simultáneas
LOCK_FILE="/var/lock/casata-update.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo -e "${RED}Ya hay una actualización en curso. Espera a que termine.${NC}"
    exit 1
fi

# Función de limpieza (libera el lock al salir)
cleanup() {
    flock -u 200 2>/dev/null
    rm -f /tmp/casata_update_*.tmp 2>/dev/null
}
trap cleanup EXIT

echo -e "${YELLOW}Actualizando ecosistema de paquetes Casata...${NC}"

# Comprobar si hay metarepos
if [ -z "$(ls -A "$METAREPOS_DIR" 2>/dev/null)" ]; then
    echo -e "${RED}No hay metarepos agregados. Usa 'casata add repo URL' primero.${NC}"
    exit 0
fi

ERRORES=0
TOTAL_METAREPOS=0

for REPO_FILE in "$METAREPOS_DIR"/*.json; do
    [ -f "$REPO_FILE" ] || continue
    TOTAL_METAREPOS=$((TOTAL_METAREPOS + 1))

    # Leer la URL del metarepo (campo "metarepo")
    METAREPO_URL=$(jq -r '.metarepo // empty' "$REPO_FILE")
    if [ -n "$METAREPO_URL" ]; then
        echo -e "\n${BLUE}🔄 Actualizando metarepo:${NC} $(jq -r '.name // "desconocido"' "$REPO_FILE")"

        # Descargar a un archivo temporal
        TEMP_META=$(mktemp /tmp/casata_update_XXXXXX.tmp)
        if wget -q --timeout=30 --tries=2 -O "$TEMP_META" "$METAREPO_URL"; then
            # Validar que sea JSON válido
            if jq empty "$TEMP_META" 2>/dev/null; then
                # Reemplazar solo si la descarga y validación fueron exitosas
                mv "$TEMP_META" "$REPO_FILE"
                echo -e "${GREEN}✓ Metarepo actualizado correctamente${NC}"
            else
                echo -e "${RED}✗ El archivo descargado no es un JSON válido. Se conserva la versión anterior.${NC}"
                rm -f "$TEMP_META"
                ((ERRORES++))
            fi
        else
            echo -e "${RED}✗ Falló la descarga del metarepo. Se conserva la versión local.${NC}"
            rm -f "$TEMP_META"
            ((ERRORES++))
        fi
    fi

    # Si el archivo aún existe (no se borró por error), procesar sus paquetes
    if [ ! -f "$REPO_FILE" ]; then
        continue
    fi

    REPO_NAME=$(jq -r '.name // "Desconocido"' "$REPO_FILE")
    echo -e "\n${GREEN}► Sincronizando paquetes desde:${NC} $REPO_NAME"

    # Leer cada entrada del metarepo (excluyendo "name" y "metarepo")
    while read -r PKG_NAME SINGREPO_URL; do
        if [ -z "$PKG_NAME" ] || [ -z "$SINGREPO_URL" ]; then
            continue
        fi

        echo -e "  -> Procesando paquete: ${YELLOW}$PKG_NAME${NC}"

        # 1. Descargar el singrepo
        TEMP_SING=$(mktemp /tmp/casata_update_XXXXXX.tmp)
        if wget -q --timeout=20 --tries=2 -O "$TEMP_SING" "$SINGREPO_URL"; then
            if jq empty "$TEMP_SING" 2>/dev/null; then
                mv "$TEMP_SING" "$SINGREPOS_DIR/${PKG_NAME}.json"
                echo -e "     ${GREEN}✓ Singrepo actualizado${NC}"
            else
                echo -e "     ${RED}✗ Singrepo descargado pero JSON inválido${NC}"
                rm -f "$TEMP_SING"
                ((ERRORES++))
                continue
            fi
        else
            echo -e "     ${RED}✗ Falló la descarga del singrepo${NC}"
            rm -f "$TEMP_SING"
            ((ERRORES++))
            continue
        fi

        # 2. Leer data_url del singrepo
        DATA_URL=$(jq -r '.data_url // empty' "$SINGREPOS_DIR/${PKG_NAME}.json")
        if [ -z "$DATA_URL" ]; then
            echo -e "     ${YELLOW}⚠ No hay data_url en el singrepo. Saltando datos.${NC}"
            continue
        fi

        # 3. Descargar los datos (metadatos del paquete)
        echo -n "     ↳ Descargando metadatos... "
        TEMP_DATA=$(mktemp /tmp/casata_update_XXXXXX.tmp)
        if wget -q --timeout=20 --tries=2 -O "$TEMP_DATA" "$DATA_URL"; then
            if jq empty "$TEMP_DATA" 2>/dev/null; then
                mv "$TEMP_DATA" "$DATA_DIR/${PKG_NAME}.json"
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FALLO (JSON inválido)${NC}"
                rm -f "$TEMP_DATA"
                ((ERRORES++))
            fi
        else
            echo -e "${RED}FALLO (error de red)${NC}"
            rm -f "$TEMP_DATA"
            ((ERRORES++))
        fi
    done < <(jq -r 'to_entries[] | select(.key != "name" and .key != "metarepo") | "\(.key) \(.value)"' "$REPO_FILE")

done

# Resumen final
echo ""
if [ $ERRORES -eq 0 ]; then
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Actualización completada sin errores.${NC}"
    echo -e "Metarepos procesados: $TOTAL_METAREPOS"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
else
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠ Actualización completada con $ERRORES error(es).${NC}"
    echo -e "Metarepos procesados: $TOTAL_METAREPOS"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    exit 1
fi
