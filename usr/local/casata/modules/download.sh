#!/bin/bash
# /usr/local/casata/modules/download.sh
# Descarga paquetes de Casata sin instalarlos.
# Uso: casata download [--extract|-e] <paquete> [paquete2 ...]

set -euo pipefail

CASATA_ROOT="/usr/local/casata"
SINGREPOS_DIR="$CASATA_ROOT/repos/singrepos"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<'EOF'
Uso: casata download [OPCIONES] <paquete> [paquete2 ...]

Descarga el archivo ZIP/TAR del paquete en la carpeta de descargas del usuario,
respetando XDG_DOWNLOAD_DIR de ~/.config/user-dirs.dirs.

Opciones:
  -e, --extract    Descomprimir el paquete descargado y eliminar el comprimido.
  -h, --help       Mostrar esta ayuda.

El archivo se guarda como <nombre_original>.casata (ej. app.tar.gz.casata).
EOF
}

get_download_dir() {
    local user_home="$1"
    local user_dirs="$user_home/.config/user-dirs.dirs"
    local xdg_dir=""

    if [ -f "$user_dirs" ]; then
        xdg_dir=$(sed -n 's/^[[:space:]]*XDG_DOWNLOAD_DIR=//p' "$user_dirs" | head -1)
        if [ -n "$xdg_dir" ]; then
            xdg_dir=$(printf '%s' "$xdg_dir" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
        fi
    fi

    if [ -z "$xdg_dir" ] && [ -n "${XDG_DOWNLOAD_DIR:-}" ]; then
        xdg_dir="$XDG_DOWNLOAD_DIR"
    fi

    if [ -z "$xdg_dir" ]; then
        printf '%s' "$user_home/Descargas"
        return
    fi

    xdg_dir="${xdg_dir//\$HOME/$user_home}"
    xdg_dir="${xdg_dir//\$\{HOME\}/$user_home}"
    if [[ "$xdg_dir" == "~"* ]]; then
        xdg_dir="$user_home${xdg_dir:1}"
    fi
    if [[ "$xdg_dir" != /* ]]; then
        xdg_dir="$user_home/$xdg_dir"
    fi
    if [ "$xdg_dir" != "/" ]; then
        xdg_dir="${xdg_dir%/}"
    fi

    printf '%s' "$xdg_dir"
}

extract_archive() {
    local archive_path="$1"
    local dest_dir="$2"
    local original_filename="$3"
    local lower

    lower=$(printf '%s' "$original_filename" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *.zip)
            command -v unzip >/dev/null || { echo -e "${RED}Error: 'unzip' no está instalado.${NC}" >&2; return 1; }
            unzip -q -o "$archive_path" -d "$dest_dir"
            ;;
        *.tar.gz|*.tgz)
            command -v tar >/dev/null || { echo -e "${RED}Error: 'tar' no está instalado.${NC}" >&2; return 1; }
            tar -xzf "$archive_path" -C "$dest_dir"
            ;;
        *.tar.xz|*.txz)
            command -v tar >/dev/null || { echo -e "${RED}Error: 'tar' no está instalado.${NC}" >&2; return 1; }
            tar -xJf "$archive_path" -C "$dest_dir"
            ;;
        *.tar.bz2|*.tbz2)
            command -v tar >/dev/null || { echo -e "${RED}Error: 'tar' no está instalado.${NC}" >&2; return 1; }
            tar -xjf "$archive_path" -C "$dest_dir"
            ;;
        *.tar)
            command -v tar >/dev/null || { echo -e "${RED}Error: 'tar' no está instalado.${NC}" >&2; return 1; }
            tar -xf "$archive_path" -C "$dest_dir"
            ;;
        *)
            echo -e "${RED}Error: Formato no soportado para extracción: $original_filename${NC}" >&2
            return 1
            ;;
    esac
}

download_one() {
    local pkg="$1"
    local extract="$2"
    local download_url original_filename final_filename final_path

    if [[ "$pkg" == */* ]]; then
        echo -e "${RED}Error: Nombre de paquete inválido: '$pkg'.${NC}" >&2
        return 1
    fi

    local singrepo_file="$SINGREPOS_DIR/${pkg}.json"
    if [ ! -f "$singrepo_file" ]; then
        echo -e "${RED}Error: El paquete '$pkg' no está indexado. Ejecuta 'casata update'.${NC}" >&2
        return 1
    fi

    if ! download_url=$(jq -r '.download_url // empty' "$singrepo_file" 2>/dev/null); then
        echo -e "${RED}Error: El singrepo de '$pkg' tiene JSON inválido.${NC}" >&2
        return 1
    fi

    if [ -z "$download_url" ]; then
        echo -e "${RED}Error: El singrepo de '$pkg' no tiene download_url.${NC}" >&2
        return 1
    fi

    original_filename=$(basename "$download_url" | cut -d '?' -f1)
    if [ -z "$original_filename" ]; then
        echo -e "${RED}Error: No se pudo determinar el nombre del archivo para '$pkg'.${NC}" >&2
        return 1
    fi

    final_filename="${original_filename}.casata"
    final_path="$DOWNLOAD_DIR/$final_filename"

    mkdir -p "$DOWNLOAD_DIR"

    echo -e "${GREEN}Descargando '$pkg'...${NC}"
    echo -e "  URL:     ${YELLOW}$download_url${NC}"
    echo -e "  Destino: ${YELLOW}$final_path${NC}"

    if ! wget -q --show-progress --timeout=30 --tries=2 -O "$final_path" "$download_url"; then
        echo -e "${RED}Error: Falló la descarga de '$pkg'.${NC}" >&2
        rm -f "$final_path" 2>/dev/null || true
        return 1
    fi

    if [ ! -s "$final_path" ]; then
        echo -e "${RED}Error: La descarga de '$pkg' resultó vacía.${NC}" >&2
        rm -f "$final_path" 2>/dev/null || true
        return 1
    fi

    echo -e "${GREEN}✔ Descargado: ${YELLOW}$final_filename${NC}"

    if [ "$extract" -eq 1 ]; then
        echo -e "${YELLOW}Descomprimiendo '$final_filename'...${NC}"
        if ! extract_archive "$final_path" "$DOWNLOAD_DIR" "$original_filename"; then
            echo -e "${RED}Error: No se pudo descomprimir '$final_filename'.${NC}" >&2
            return 1
        fi
        rm -f "$final_path"
        echo -e "${GREEN}✔ Paquete extraído en: ${YELLOW}$DOWNLOAD_DIR${NC}"
    fi

    return 0
}

# ==========================
# Comprobaciones iniciales
# ==========================
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}" >&2
    exit 1
fi

EXTRACT=0
PACKAGES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--extract)
            EXTRACT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo -e "${RED}Opción desconocida: $1${NC}" >&2
            usage
            exit 1
            ;;
        *)
            PACKAGES+=("$1")
            shift
            ;;
    esac
done

if [ ${#PACKAGES[@]} -eq 0 ]; then
    usage
    exit 1
fi

# Determinar el home del usuario real (incluso con sudo)
TARGET_USER_HOME="${HOME:-/root}"
if [ "${EUID:-0}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    detected="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$detected" ]; then
        TARGET_USER_HOME="$detected"
    fi
fi

DOWNLOAD_DIR="$(get_download_dir "$TARGET_USER_HOME")"

# ==========================
# Proceso por paquete
# ==========================
FAILED=()
for PKG in "${PACKAGES[@]}"; do
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Descargando paquete: $PKG${NC}"
    echo -e "${GREEN}========================================${NC}"

    if download_one "$PKG" "$EXTRACT"; then
        echo -e "${GREEN}✔ $PKG descargado correctamente.${NC}"
    else
        echo -e "${RED}✖ Falló la descarga de $PKG.${NC}"
        FAILED+=("$PKG")
    fi
done

echo -e "\n${GREEN}════════════════════════════════════════${NC}"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ Todos los paquetes se descargaron correctamente.${NC}"
else
    echo -e "${RED}✖ Los siguientes paquetes fallaron: ${FAILED[*]}${NC}"
fi
echo -e "${GREEN}════════════════════════════════════════${NC}"

if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
fi

exit 0
