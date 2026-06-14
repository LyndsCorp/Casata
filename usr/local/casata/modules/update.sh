#!/bin/bash
# /usr/local/casata/modules/update.sh

CASATA_ROOT="/usr/local/casata"
METAREPOS_DIR="$CASATA_ROOT/repos/metarepos"
SINGREPOS_DIR="$CASATA_ROOT/repos/singrepos"
DATA_DIR="$CASATA_ROOT/data"

# Crear directorios si no existen
mkdir -p "$METAREPOS_DIR"
mkdir -p "$SINGREPOS_DIR"
mkdir -p "$DATA_DIR"

echo -e "${YELLOW}Actualizando ecosistema de paquetes Casata...${NC}"

if [ -z "$(ls -A "$METAREPOS_DIR" 2>/dev/null)" ]; then
    echo -e "${RED}No hay metarepos agregados. Usa 'casata add repo URL' primero.${NC}"
    exit 0
fi

ERRORES=0

for REPO_FILE in "$METAREPOS_DIR"/*.json; do
    # Actualizar el metarepo a sí mismo primero
    METAREPO_URL=$(jq -r '.metarepo // empty' "$REPO_FILE")
    if [ -n "$METAREPO_URL" ]; then
        echo -e "\n${BLUE}🔄 Actualizando metarepo desde:${NC} $METAREPO_URL"

        WGET_ERROR=$( { wget -O "$REPO_FILE" "$METAREPO_URL" 2>&1; } )
        WGET_STATUS=$?

        if [ $WGET_STATUS -eq 0 ] && [ -f "$REPO_FILE" ] && [ -s "$REPO_FILE" ]; then
            # Validar que sea JSON válido
            if jq empty "$REPO_FILE" 2>/dev/null; then
                echo -e "${GREEN}✓ Metarepo actualizado${NC}"
            else
                echo -e "${RED}✗ Metarepo descargado pero JSON inválido${NC}"
                rm -f "$REPO_FILE"
                ((ERRORES++))
            fi
        else
            echo -e "${RED}✗ No se pudo actualizar el metarepo${NC}"
            if [ -n "$WGET_ERROR" ]; then
                echo -e "${RED}  Error: $(echo "$WGET_ERROR" | tail -1)${NC}"
            fi
            rm -f "$REPO_FILE"
            ((ERRORES++))
        fi
    fi

    # Si el metarepo se borró por error, saltar
    if [ ! -f "$REPO_FILE" ]; then
        continue
    fi

    REPO_NAME=$(jq -r '.name // "Desconocido"' "$REPO_FILE")
    echo -e "\n${GREEN}► Sincronizando desde metarepo:${NC} $REPO_NAME"

    # Leer los paquetes del metarepo (ignorando las claves "name" y "metarepo")
    while read -r PKG_NAME SINGREPO_URL; do
        if [ -z "$PKG_NAME" ] || [ -z "$SINGREPO_URL" ]; then continue; fi

        echo -e "  -> Procesando paquete: ${YELLOW}$PKG_NAME${NC}"

        # 1. Descargar el Singrepo (siempre sobrescribe)
        SINGREPO_ERROR=$( { wget -O "$SINGREPOS_DIR/${PKG_NAME}.json" "$SINGREPO_URL" 2>&1; } )
        SINGREPO_STATUS=$?

        if [ $SINGREPO_STATUS -eq 0 ] && [ -f "$SINGREPOS_DIR/${PKG_NAME}.json" ] && [ -s "$SINGREPOS_DIR/${PKG_NAME}.json" ]; then
            # Validar que sea JSON válido
            if ! jq empty "$SINGREPOS_DIR/${PKG_NAME}.json" 2>/dev/null; then
                echo -e "     ${RED}↳ FALLO: Singrepo descargado pero JSON inválido${NC}"
                rm -f "$SINGREPOS_DIR/${PKG_NAME}.json"
                ((ERRORES++))
                continue
            fi

            # 2. Leer la URL de los datos desde el singrepo recién bajado
            DATA_URL=$(jq -r '.data_url' "$SINGREPOS_DIR/${PKG_NAME}.json")

            if [ "$DATA_URL" != "null" ] && [ -n "$DATA_URL" ]; then
                # 3. Descargar los metadatos a la base de datos local (siempre sobrescribe)
                echo -n "     ↳ Actualizando base de datos local... "

                DATA_ERROR=$( { wget -O "$DATA_DIR/${PKG_NAME}.json" "$DATA_URL" 2>&1; } )
                DATA_STATUS=$?

                if [ $DATA_STATUS -eq 0 ] && [ -f "$DATA_DIR/${PKG_NAME}.json" ] && [ -s "$DATA_DIR/${PKG_NAME}.json" ]; then
                    # Validar que sea JSON válido
                    if jq empty "$DATA_DIR/${PKG_NAME}.json" 2>/dev/null; then
                        echo -e "${GREEN}COMPLETO${NC}"
                    else
                        echo -e "${RED}FALLO (JSON inválido)${NC}"
                        echo -e "     ${RED}URL: $DATA_URL${NC}"
                        rm -f "$DATA_DIR/${PKG_NAME}.json"
                        ((ERRORES++))
                    fi
                else
                    echo -e "${RED}FALLO${NC}"
                    echo -e "     ${RED}URL: $DATA_URL${NC}"
                    if [ -n "$DATA_ERROR" ]; then
                        echo -e "     ${RED}Error: $(echo "$DATA_ERROR" | tail -1)${NC}"
                    fi
                    rm -f "$DATA_DIR/${PKG_NAME}.json"
                    ((ERRORES++))
                fi
            else
                echo -e "     ${YELLOW}⚠ Sin data_url en singrepo${NC}"
            fi
        else
            echo -e "     ${RED}↳ FALLO al conectar con el singrepo${NC}"
            echo -e "     ${RED}URL: $SINGREPO_URL${NC}"
            if [ -n "$SINGREPO_ERROR" ]; then
                echo -e "     ${RED}Error: $(echo "$SINGREPO_ERROR" | tail -1)${NC}"
            fi
            rm -f "$SINGREPOS_DIR/${PKG_NAME}.json"
            ((ERRORES++))
        fi

    done < <(jq -r 'to_entries[] | select(.key != "name" and .key != "metarepo" and (.value | type == "string")) | "\(.key) \(.value)"' "$REPO_FILE")
done

if [ $ERRORES -eq 0 ]; then
    echo -e "\n${YELLOW}Base de datos de Casata actualizada correctamente.${NC}"
else
    echo -e "\n${RED}⚠ Actualización completada con $ERRORES error(es).${NC}"
    exit 1
fi
