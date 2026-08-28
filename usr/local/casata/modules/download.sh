#!/bin/bash
# /usr/local/casata/modules/download.sh
# Descarga paquetes de Casata sin instalarlos.
# Uso:
#   casata download [OPCIONES] <paquete> [paquete2 ...]
# Opciones:
#   -e, --extract        Descomprimir después de descargar y eliminar el comprimido.
#   --path <ruta>        Carpeta de destino. Por defecto se usa XDG_DOWNLOAD_DIR
#                        o ~/Descargas.
#   -h, --help           Mostrar esta ayuda.

# Copyright (C) 2026 David Baña Szymaniak

set -euo pipefail

# Cargar librería de historial
if [ -f "/usr/local/casata/lib/history-lib.sh" ]; then
    source "/usr/local/casata/lib/history-lib.sh"
fi

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

Descarga el archivo ZIP/TAR del paquete en la carpeta indicada.
Por defecto se descarga en la carpeta de descargas del usuario.

Opciones:
  -e, --extract    Descomprimir el paquete descargado y eliminar el comprimido.
  --path <ruta>    Carpeta de destino (ej. ~/Documentos).
  -h, --help       Mostrar esta ayuda.

El archivo se guarda como <nombre_paquete>.<extension>.casata (ej. app.tar.gz.casata).
EOF
}

# ------------------------------------------------------------
# Expande ~ y $HOME en una ruta dada
# ------------------------------------------------------------
expand_download_path() {
    local path="$1"
    local home="$2"

    path="${path//\$HOME/$home}"
    path="${path//\$\{HOME\}/$home}"

    if [[ "$path" == "~"* ]]; then
        path="$home${path:1}"
    fi

    if [ "$path" != "/" ]; then
        path="${path%/}"
    fi

    printf '%s' "$path"
}

# ------------------------------------------------------------
# Obtener la carpeta de descargas por defecto desde XDG
# ------------------------------------------------------------
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

    expand_download_path "$xdg_dir" "$user_home"
}

# ------------------------------------------------------------
# Extraer la extensión del archivo remoto
# ------------------------------------------------------------
get_file_extension() {
    local url="$1"
    local filename
    local lower

    filename=$(basename "$url" | cut -d '?' -f1)
    lower=$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')

    if [[ "$lower" =~ \.(tar\.gz|tar\.xz|tar\.bz2|tgz|txz|tbz2)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$lower" =~ \.([a-z0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf ''
    fi
}

# ------------------------------------------------------------
# Extraer según la extensión original
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Empaquetar una carpeta en un archivo con la extensión dada
# ------------------------------------------------------------
pack_archive() {
    local src_dir="$1"
    local archive_path="$2"
    local extension="$3"
    local parent_dir

    parent_dir=$(dirname "$src_dir")
    local folder_name
    folder_name=$(basename "$src_dir")

    case "$extension" in
        zip)
            (cd "$parent_dir" && zip -qr "$archive_path" "$folder_name")
            ;;
        tar.gz|tgz)
            (cd "$parent_dir" && tar -czf "$archive_path" "$folder_name")
            ;;
        tar.xz|txz)
            (cd "$parent_dir" && tar -cJf "$archive_path" "$folder_name")
            ;;
        tar.bz2|tbz2)
            (cd "$parent_dir" && tar -cjf "$archive_path" "$folder_name")
            ;;
        tar)
            (cd "$parent_dir" && tar -cf "$archive_path" "$folder_name")
            ;;
        *)
            echo -e "${RED}Error: Extensión de empaquetado no soportada: $extension${NC}" >&2
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# Descargar un paquete
# ------------------------------------------------------------
download_one() {
    local pkg="$1"
    local extract="$2"
    local download_url original_filename file_ext final_filename final_path
    local data_file=""

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

    # Manejo de paquetes externos
    if [[ "$download_url" == "external" || -z "$download_url" ]]; then
        data_file="$CASATA_ROOT/data/${pkg}.json"
        if [ ! -f "$data_file" ]; then
            echo -e "${RED}Error: No se encontró el archivo de datos para '$pkg'.${NC}" >&2
            return 1
        fi
        local external_metadata
        external_metadata=$(jq -r '.external_metadata // false' "$data_file" 2>/dev/null || echo "false")
        if [[ "$external_metadata" == "true" ]]; then
            download_url=$(jq -r '.release.url // empty' "$data_file" 2>/dev/null || true)
            if [ -z "$download_url" ]; then
                echo -e "${RED}Error: external_metadata es true pero no se encontró 'release.url'.${NC}" >&2
                return 1
            fi
            echo -e "${YELLOW}Usando URL de release oficial: $download_url${NC}"
        else
            echo -e "${RED}Error: El paquete no tiene download_url directa y no es un paquete externo válido.${NC}" >&2
            return 1
        fi
    fi

    original_filename=$(basename "$download_url" | cut -d '?' -f1)
    if [ -z "$original_filename" ]; then
        echo -e "${RED}Error: No se pudo determinar el nombre del archivo para '$pkg'.${NC}" >&2
        return 1
    fi

    file_ext=$(get_file_extension "$download_url")
    if [ -z "$file_ext" ]; then
        echo -e "${RED}Error: No se pudo determinar la extensión del archivo para '$pkg'.${NC}" >&2
        return 1
    fi

    final_filename="${pkg}.${file_ext}.casata"
    final_path="$DOWNLOAD_DIR/$final_filename"

    mkdir -p "$DOWNLOAD_DIR"

    # ------------------------------------------------------------------
    # Caso especial: paquete externo con metadatos adicionales
    # ------------------------------------------------------------------
    if [ -n "$data_file" ]; then
        echo -e "${GREEN}Descargando release oficial y preparando paquete completo...${NC}"
        local temp_release="$DOWNLOAD_DIR/.release_$$"
        local temp_extract="$DOWNLOAD_DIR/.extract_$$"
        mkdir -p "$temp_extract"

        # 1) Descargar release
        if ! wget -q --show-progress --timeout=30 --tries=2 -O "$temp_release" "$download_url"; then
            echo -e "${RED}Error: Falló la descarga de '$pkg'.${NC}" >&2
            rm -f "$temp_release" "$temp_extract" 2>/dev/null || true
            return 1
        fi

        # 2) Extraer
        if ! extract_archive "$temp_release" "$temp_extract" "$original_filename"; then
            echo -e "${RED}Error: No se pudo descomprimir '$original_filename'.${NC}" >&2
            rm -rf "$temp_release" "$temp_extract"
            return 1
        fi

        # 3) Detectar la carpeta raíz (como hace Dolphin: si hay una única carpeta y no hay archivos sueltos)
        local root_dir=""
        local count_dirs=0
        local count_files=0
        local first_dir=""
        for item in "$temp_extract"/*; do
            if [ -d "$item" ]; then
                count_dirs=$((count_dirs+1))
                first_dir="$item"
            elif [ -f "$item" ]; then
                count_files=$((count_files+1))
            fi
        done

        if [ $count_dirs -eq 1 ] && [ $count_files -eq 0 ]; then
            root_dir="$first_dir"
            # Renombrar al nombre del paquete si es diferente
            if [ "$(basename "$root_dir")" != "$pkg" ]; then
                mv "$root_dir" "$temp_extract/$pkg"
                root_dir="$temp_extract/$pkg"
                echo -e "${YELLOW}Carpeta raíz renombrada a '$pkg'.${NC}"
            fi
        else
            root_dir="$temp_extract"
        fi

        # 4) Descargar archivos externos dentro de root_dir
        local -a external_urls=()
        while IFS= read -r url; do
            [ -n "$url" ] && external_urls+=("$url")
        done < <(jq -r '.external_files? // [] | .[]' "$data_file" 2>/dev/null || true)

        if [ ${#external_urls[@]} -gt 0 ]; then
            echo -e "${YELLOW}Descargando archivos externos...${NC}"
            for url in "${external_urls[@]}"; do
                local clean_url="${url%%\?*}"
                local fname
                fname=$(basename "$clean_url" 2>/dev/null || true)
                if [ -z "$fname" ] || [ "$fname" == "/" ]; then
                    fname="external_file_$(date +%s%N)"
                fi
                echo -e "   ${YELLOW}→ $fname${NC}"
                if ! wget -q --show-progress -O "$root_dir/$fname" "$url"; then
                    echo -e "${RED}Error al descargar $url${NC}" >&2
                fi
            done
        fi

        # 5) Generar GUIDE.json si hay campo 'guide'
        local guide_array
        guide_array=$(jq -c '.guide // empty' "$data_file" 2>/dev/null || true)
        if [ -n "$guide_array" ] && [ "$guide_array" != "[]" ] && [ "$guide_array" != "null" ]; then
            if [ ! -f "$root_dir/GUIDE.json" ]; then
                echo -e "${YELLOW}Generando GUIDE.json...${NC}"
                if jq -n --argjson links "$guide_array" '{links: $links}' > "$root_dir/GUIDE.json"; then
                    echo -e "${GREEN}✔ GUIDE.json creado.${NC}"
                else
                    echo -e "${RED}Error al generar GUIDE.json.${NC}" >&2
                fi
            fi
        fi

        # 6) Decidir si empaquetar o extraer
        if [ "$extract" -eq 1 ]; then
            # Mover la carpeta raíz al destino final
            local dest_pkg_dir="$DOWNLOAD_DIR/$pkg"
            if [ -d "$dest_pkg_dir" ]; then
                rm -rf "$dest_pkg_dir"
            fi
            mv "$root_dir" "$dest_pkg_dir"
            echo -e "${GREEN}✔ Paquete extraído en: ${YELLOW}$DOWNLOAD_DIR${NC}"
            log_event "EXTRACT" "package=\"$pkg\" destination=\"$DOWNLOAD_DIR\" status=OK"
        else
            # Empaquetar de nuevo
            local final_pack_path="$final_path"
            if [ -f "$final_pack_path" ]; then
                rm -f "$final_pack_path"
            fi
            if ! pack_archive "$root_dir" "$final_pack_path" "$file_ext"; then
                echo -e "${RED}Error al empaquetar el paquete final.${NC}" >&2
                rm -rf "$temp_release" "$temp_extract"
                return 1
            fi
            echo -e "${GREEN}✔ Paquete completo guardado: ${YELLOW}$final_filename${NC}"
            log_download "$download_url" "$final_pack_path" "OK"
        fi

        # Limpiar temporales
        rm -rf "$temp_release" "$temp_extract"
        return 0
    fi

    # ------------------------------------------------------------------
    # Caso normal: paquete sin metadatos externos
    # ------------------------------------------------------------------
    echo -e "${GREEN}Descargando '$pkg'...${NC}"
    echo -e "  URL:     ${YELLOW}$download_url${NC}"
    echo -e "  Destino: ${YELLOW}$final_path${NC}"

    if ! wget -q --show-progress --timeout=30 --tries=2 -O "$final_path" "$download_url"; then
        echo -e "${RED}Error: Falló la descarga de '$pkg'.${NC}" >&2
        rm -f "$final_path" 2>/dev/null || true
        log_download "$download_url" "$final_path" "ERROR"
        return 1
    fi

    if [ ! -s "$final_path" ]; then
        echo -e "${RED}Error: La descarga de '$pkg' resultó vacía.${NC}" >&2
        rm -f "$final_path" 2>/dev/null || true
        log_download "$download_url" "$final_path" "ERROR"
        return 1
    fi

    echo -e "${GREEN}✔ Descargado: ${YELLOW}$final_filename${NC}"
    log_download "$download_url" "$final_path" "OK"

    if [ "$extract" -eq 1 ]; then
        echo -e "${YELLOW}Descomprimiendo '$final_filename'...${NC}"
        local temp_extract="$DOWNLOAD_DIR/.extract_$$"
        mkdir -p "$temp_extract"
        if ! extract_archive "$final_path" "$temp_extract" "$original_filename"; then
            echo -e "${RED}Error: No se pudo descomprimir '$final_filename'.${NC}" >&2
            rm -rf "$temp_extract"
            return 1
        fi
        rm -f "$final_path"

        # Mover contenido a carpeta con nombre del paquete (si no existe)
        local pkg_dir="$DOWNLOAD_DIR/$pkg"
        if [ -d "$pkg_dir" ]; then
            rm -rf "$pkg_dir"
        fi
        mkdir -p "$pkg_dir"
        shopt -s dotglob nullglob
        mv "$temp_extract"/* "$pkg_dir"/ 2>/dev/null || true
        shopt -u dotglob nullglob
        rm -rf "$temp_extract"

        echo -e "${GREEN}✔ Paquete extraído en: ${YELLOW}$DOWNLOAD_DIR${NC}"
        log_event "EXTRACT" "package=\"$pkg\" destination=\"$DOWNLOAD_DIR\" status=OK"
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
CUSTOM_PATH=""
PACKAGES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--extract)
            EXTRACT=1
            shift
            ;;
        --path)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: --path requiere un argumento.${NC}" >&2
                exit 1
            fi
            CUSTOM_PATH="$2"
            shift 2
            ;;
        --path=*)
            CUSTOM_PATH="${1#--path=}"
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

# Determinar el home del usuario real
TARGET_USER_HOME="${HOME:-/root}"
if [ "${EUID:-0}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    detected="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$detected" ]; then
        TARGET_USER_HOME="$detected"
    fi
fi

if [ -n "$CUSTOM_PATH" ]; then
    DOWNLOAD_DIR="$(expand_download_path "$CUSTOM_PATH" "$TARGET_USER_HOME")"
else
    DOWNLOAD_DIR="$(get_download_dir "$TARGET_USER_HOME")"
fi

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
