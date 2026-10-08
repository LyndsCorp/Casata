#!/bin/bash
# /usr/local/casata/modules/remove.sh
# Copyright (C) 2026 David Baña Szymaniak

shopt -s nullglob

# Cargar librería de historial
if [ -f "/usr/local/casata/lib/history-lib.sh" ]; then
    source "/usr/local/casata/lib/history-lib.sh"
fi

GLOBAL_ROOT="/usr/local/casata"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ------------------------------------------------------------
# Resolver ruta canónica (con fallback si realpath no existe)
# ------------------------------------------------------------
canonical_path() {
    local path="$1"
    if command -v realpath &>/dev/null; then
        realpath -m "$path" 2>/dev/null || echo "$path"
    else
        echo "$path"
    fi
}

# ------------------------------------------------------------
# Resolver el destino real de un enlace simbólico, aunque sea
# relativo. Devuelve la ruta absoluta canónica o falla.
# ------------------------------------------------------------
resolve_link_target() {
    local link="$1"
    local raw
    raw=$(readlink "$link" 2>/dev/null) || return 1
    [ -n "$raw" ] || return 1

    # Si el destino es relativo, unirlo al directorio del enlace
    if [[ "$raw" != /* ]]; then
        raw="$(dirname "$link")/$raw"
    fi

    canonical_path "$raw"
}

# Función para eliminar un solo paquete
remove_one() {
    local PKG_NAME="$1"
    local AUTO_YES="$2"
    local USER_INSTALL="$3"

    # Configurar rutas
    if [ $USER_INSTALL -eq 1 ]; then
        APPS_DIR="$HOME/.local/casata/apps"
        GUIDE_TARGET="GUIDE-USER.json"
        INSTALL_TYPE="Usuario"
    else
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}Error: La desinstalación global requiere permisos de root.${NC}"
            echo -e "Usa ${YELLOW}sudo casata remove $PKG_NAME${NC} o ${YELLOW}casata remove --user $PKG_NAME${NC}."
            INSTALL_TYPE="Global"
            return 1
        fi
        APPS_DIR="$GLOBAL_ROOT/apps"
        GUIDE_TARGET="GUIDE.json"
        INSTALL_TYPE="Global"
    fi

    APP_DIR="$APPS_DIR/${PKG_NAME}"

    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}Error: El paquete '$PKG_NAME' no está instalado ($INSTALL_TYPE).${NC}"
        return 1
    fi

    if [ $AUTO_YES -eq 0 ]; then
        echo -e "${YELLOW}Se eliminará $PKG_NAME ($INSTALL_TYPE) y todos sus enlaces.${NC}"
        read -p "¿Estás seguro? [S/n] " response < /dev/tty
        if [[ "$response" =~ ^([nN][oO]|[nN])$ ]]; then
            echo "Desinstalación abortada para $PKG_NAME."
            return 1
        fi
    fi

    echo -e "${GREEN}Desinstalando $PKG_NAME ($INSTALL_TYPE)...${NC}"

    GUIDE_FILE="$APP_DIR/$GUIDE_TARGET"

    # Eliminar enlaces simbólicos SOLO si apuntan a este paquete
    if [ -f "$GUIDE_FILE" ]; then
        echo " -> Eliminando enlaces del sistema..."
        while read -r item; do
            DEST=$(echo "$item" | jq -r '.dest')
            LINK_NAME=$(echo "$item" | jq -r '.name')
            FILE=$(echo "$item" | jq -r '.file')

            # Saltar entradas malformadas
            [ "$DEST" == "null" ] || [ "$LINK_NAME" == "null" ] || [ "$FILE" == "null" ] && continue
            [ -z "$DEST" ] && continue
            [ -z "$LINK_NAME" ] && continue
            [ -z "$FILE" ] && continue

            DEST="${DEST/#\~/$HOME}"
            DEST="${DEST//\$HOME/$HOME}"
            TARGET_LINK="$DEST/$LINK_NAME"

            # ¿Existe algo en la ruta?
            if [ ! -e "$TARGET_LINK" ] && [ ! -L "$TARGET_LINK" ]; then
                echo -e "   [=] No existía: $LINK_NAME"
                continue
            fi

            # ¿Es un enlace simbólico?
            if [ ! -L "$TARGET_LINK" ]; then
                echo -e "   [!] Omitido (no es un enlace): $TARGET_LINK"
                continue
            fi

            # Comparar el destino real del enlace con el archivo esperado
            # dentro del paquete. Sólo se borra si coinciden.
            expected_real=$(canonical_path "$APP_DIR/$FILE")
            link_real=$(resolve_link_target "$TARGET_LINK" 2>/dev/null || echo "")

            if [ -z "$link_real" ]; then
                echo -e "   [!] Omitido (no se pudo resolver el enlace): $TARGET_LINK"
                continue
            fi

            if [ "$link_real" = "$expected_real" ]; then
                rm -f "$TARGET_LINK"
                echo -e "   [-] Enlace eliminado: ${RED}$LINK_NAME${NC}  ($TARGET_LINK -> $link_real)"
                log_symlink_removed "$LINK_NAME" "$TARGET_LINK"
            else
                # El enlace apunta a otro sitio: NO es nuestro, no lo tocamos.
                echo -e "   ${YELLOW}[!] Omitido (el enlace NO pertenece a '$PKG_NAME'):${NC}"
                echo -e "       $TARGET_LINK -> $link_real"
                echo -e "       (esperado -> $expected_real)"
            fi
        done < <(jq -c '.links[]' "$GUIDE_FILE" 2>/dev/null)
    else
        echo -e "${YELLOW}Aviso: No se encontró $GUIDE_TARGET. No se eliminarán enlaces, solo la carpeta base.${NC}"
    fi

    echo " -> Eliminando archivos base de la aplicación..."
    rm -rf "$APP_DIR"

    echo -e "${GREEN}¡$PKG_NAME desinstalado correctamente!${NC}"
    log_package_removed "$PKG_NAME" "$INSTALL_TYPE" "SUCCESS"
    return 0
}

# --- INICIO DEL SCRIPT (múltiples paquetes) ---
AUTO_YES=0
USER_INSTALL=0
PACKAGES=()

for arg in "$@"; do
    case "$arg" in
        -y) AUTO_YES=1 ;;
        --user) USER_INSTALL=1 ;;
        -*)
            echo -e "${RED}Opción desconocida: $arg${NC}"
            exit 1
            ;;
        *) PACKAGES+=("$arg") ;;
    esac
done

if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo -e "${RED}Error: Falta el nombre del paquete.${NC}"
    exit 1
fi

FAILED=()
for PKG in "${PACKAGES[@]}"; do
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Desinstalando: $PKG${NC}"
    echo -e "${GREEN}========================================${NC}"
    if remove_one "$PKG" "$AUTO_YES" "$USER_INSTALL"; then
        echo -e "${GREEN}✔ $PKG desinstalado correctamente.${NC}"
    else
        echo -e "${RED}✖ Falló la desinstalación de $PKG.${NC}"
        log_package_removed "$PKG" "${INSTALL_TYPE:-desconocido}" "FAILURE"
        FAILED+=("$PKG")
    fi
done

echo -e "\n${GREEN}════════════════════════════════════════${NC}"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ Todos los paquetes se desinstalaron correctamente.${NC}"
else
    echo -e "${RED}✖ Los siguientes paquetes fallaron: ${FAILED[*]}${NC}"
fi
echo -e "${GREEN}════════════════════════════════════════${NC}"

if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
fi
exit 0
