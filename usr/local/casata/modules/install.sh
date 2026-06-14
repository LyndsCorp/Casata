#!/bin/bash
# /usr/local/casata/modules/install.sh - soporte para múltiples paquetes

shopt -s nullglob
set -euo pipefail

GLOBAL_ROOT="/usr/local/casata"
DATA_DIR="$GLOBAL_ROOT/data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Variables globales para limpieza
TEMP_DIR=""
EXTRACT_DIR=""

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    if [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ]; then
        rm -rf "$EXTRACT_DIR"
    fi
}
trap cleanup EXIT

detect_pkg_manager() {
    if command -v apt &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v zypper &>/dev/null; then echo "zypper"
    else echo ""; fi
}

install_system_deps() {
    local deps="$1"
    local pkg_manager=$(detect_pkg_manager)
    if [ -z "$pkg_manager" ]; then
        echo -e "${RED}No se detectó gestor de paquetes. Instale manualmente: $deps${NC}"
        return 1
    fi
    echo -e "${YELLOW}Usando $pkg_manager para instalar: $deps${NC}"
    case "$pkg_manager" in
        apt) apt update && apt install -y $deps ;;
        dnf|yum) $pkg_manager install -y $deps ;;
        pacman) pacman -S --noconfirm $deps ;;
        zypper) zypper install -y $deps ;;
    esac
}

force_remove() {
    local app_dir="$1"
    local guide_target="$2"
    echo -e "${YELLOW}Eliminando instalación anterior...${NC}"
    if [ -f "$app_dir/$guide_target" ]; then
        jq -c '.links[]' "$app_dir/$guide_target" 2>/dev/null | while read -r item; do
            DEST=$(echo "$item" | jq -r '.dest')
            LINK_NAME=$(echo "$item" | jq -r '.name')
            [ "$DEST" == "null" ] || [ "$LINK_NAME" == "null" ] && continue
            DEST="${DEST/#\~/$HOME}"
            DEST="${DEST//\$HOME/$HOME}"
            TARGET_LINK="$DEST/$LINK_NAME"
            if [ -L "$TARGET_LINK" ]; then
                rm -f "$TARGET_LINK"
                echo -e "   [-] Enlace eliminado: $LINK_NAME"
            fi
        done
    fi
    rm -rf "$app_dir"
}

ask_overwrite() {
    local target="$1"
    local app_name="$2"
    echo -e "${YELLOW}Advertencia: '$target' ya existe y no es un enlace a $app_name.${NC}"
    read -p "¿Sobrescribirlo? (perderás el archivo original) [s/N]: " resp < /dev/tty
    if [[ "$resp" =~ ^[sSyY] ]]; then
        rm -rf "$target"
        echo -e "${GREEN}Archivo eliminado. Continuando...${NC}"
        return 0
    else
        echo -e "${RED}Instalación abortada por seguridad.${NC}"
        exit 1
    fi
}

# Función para instalar un solo paquete
install_one() {
    local PKG_NAME="$1"
    local AUTO_YES="$2"
    local DOWNLOAD_ONLY="$3"
    local USER_INSTALL="$4"

    # Configuración de rutas
    if [ $USER_INSTALL -eq 1 ]; then
        APPS_DIR="$HOME/.local/casata/apps"
        GUIDE_TARGET="GUIDE-USER.json"
        INSTALL_TYPE="Usuario"
    else
        [ "$EUID" -ne 0 ] && { echo -e "${RED}Instalación global requiere root.${NC}"; return 1; }
        APPS_DIR="$GLOBAL_ROOT/apps"
        GUIDE_TARGET="GUIDE.json"
        INSTALL_TYPE="Global"
    fi

    mkdir -p "$APPS_DIR"
    APP_DIR="$APPS_DIR/${PKG_NAME}"

    # Verificar que el paquete esté indexado
    SINGREPO_FILE="$GLOBAL_ROOT/repos/singrepos/${PKG_NAME}.json"
    if [ ! -f "$SINGREPO_FILE" ]; then
        echo -e "${RED}Error: El paquete '$PKG_NAME' no está indexado.${NC}"
        return 1
    fi

    DOWNLOAD_URL=$(jq -r '.download_url // empty' "$SINGREPO_FILE")
    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}Error: No hay download_url en el singrepo.${NC}"
        return 1
    fi

    PKG_FILE="$DATA_DIR/${PKG_NAME}.json"
    if [ ! -f "$PKG_FILE" ]; then
        echo -e "${RED}Error: Base de datos local no encontrada. Ejecute 'casata update' primero.${NC}"
        return 1
    fi

    # Leer metadatos
    REPO_VERSION=$(jq -r '.version // "0.0.0"' "$PKG_FILE")
    REPO_DEPS=$(jq -r '.dependencies[]? // empty' "$PKG_FILE")

    # Comprobar si ya está instalado y comparar versiones
    INSTALLED_VERSION=""
    NEED_UPDATE=0
    if [ -d "$APP_DIR" ]; then
        if [ -f "$APP_DIR/VERSION" ]; then
            INSTALLED_VERSION=$(cat "$APP_DIR/VERSION")
            echo -e "${YELLOW}Versión instalada: $INSTALLED_VERSION${NC}"
            echo -e "${YELLOW}Versión en repositorio: $REPO_VERSION${NC}"
            OLDER=$(printf '%s\n' "$INSTALLED_VERSION" "$REPO_VERSION" | sort -V | head -n1)
            if [ "$OLDER" = "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$REPO_VERSION" ]; then
                NEED_UPDATE=1
                echo -e "${GREEN}Hay una actualización disponible.${NC}"
            elif [ "$INSTALLED_VERSION" = "$REPO_VERSION" ]; then
                echo -e "${GREEN}Ya tienes la última versión.${NC}"
                if [ $AUTO_YES -eq 0 ]; then
                    read -p "¿Reinstalar igualmente? [s/N] " rein < /dev/tty
                    [[ ! "$rein" =~ ^[sSyY] ]] && return 0
                    NEED_UPDATE=2
                else
                    echo -e "${YELLOW}Usando -y: se reinstalará.${NC}"
                    NEED_UPDATE=2
                fi
            else
                echo -e "${GREEN}La versión instalada es más reciente que la del repositorio. No se hará nada.${NC}"
                return 0
            fi
        else
            echo -e "${YELLOW}Paquete instalado pero sin archivo VERSION. Se reinstalará.${NC}"
            NEED_UPDATE=2
        fi
    fi

    if [ $NEED_UPDATE -eq 1 ] || [ $NEED_UPDATE -eq 2 ]; then
        echo -e "${YELLOW}Preparando actualización/reinstalación...${NC}"
        force_remove "$APP_DIR" "$GUIDE_TARGET"
    fi

    # Gestión de dependencias
    if [ -n "$REPO_DEPS" ]; then
        echo -e "\n${YELLOW}Dependencias para $PKG_NAME:${NC}"
        echo "$REPO_DEPS" | sed 's/^/  • /'
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
            [[ "$resp" =~ ^[Nn] ]] && { echo "Instalación abortada."; return 1; }
        fi
        if [ $USER_INSTALL -eq 1 ]; then
            MISSING=""
            for dep in $REPO_DEPS; do
                if ! dpkg -s "$dep" &>/dev/null && ! rpm -q "$dep" &>/dev/null && ! pacman -Q "$dep" &>/dev/null; then
                    MISSING="$MISSING $dep"
                fi
            done
            if [ -n "$MISSING" ]; then
                echo -e "${RED}Faltan dependencias: $MISSING${NC}"
                read -p "¿Continuar sin ellas? [s/N] " resp < /dev/tty
                [[ ! "$resp" =~ ^[Ss] ]] && return 1
            fi
        else
            install_system_deps "$(echo "$REPO_DEPS" | tr '\n' ' ')" || return 1
        fi
    fi

    # Descarga y extracción
    mkdir -p "$APP_DIR"
    ARCHIVE_NAME=$(basename "$DOWNLOAD_URL" | cut -d '?' -f1)
    ARCHIVE_PATH="$APP_DIR/$ARCHIVE_NAME"
    EXTRACT_DIR=$(mktemp -d)

    echo -e "${GREEN}Descargando $PKG_NAME...${NC}"
    wget -q --show-progress -O "$ARCHIVE_PATH" "$DOWNLOAD_URL" || { echo -e "${RED}Error descarga.${NC}"; return 1; }

    case "$ARCHIVE_NAME" in
        *.zip) unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR" ;;
        *.tar.gz|*.tgz) tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" ;;
        *.tar.xz) tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" ;;
        *) echo -e "${RED}Formato no soportado.${NC}"; return 1 ;;
    esac

    SRC_DIR=$(find "$EXTRACT_DIR" -name "VERSION" -exec dirname {} \; | head -1)
    [ -z "$SRC_DIR" ] && SRC_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -z "$SRC_DIR" ] && SRC_DIR="$EXTRACT_DIR"

    mv "$SRC_DIR"/* "$APP_DIR/" 2>/dev/null || mv "$SRC_DIR"/.??* "$APP_DIR/" 2>/dev/null || true
    rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
    EXTRACT_DIR=""

    [ $DOWNLOAD_ONLY -eq 1 ] && { echo -e "${YELLOW}Descargado en $APP_DIR (sin enlaces).${NC}"; return 0; }

    # Crear enlaces simbólicos
    echo -e "${YELLOW}Configurando enlaces...${NC}"
    GUIDE_FILE="$APP_DIR/$GUIDE_TARGET"
    if [ -f "$GUIDE_FILE" ]; then
        while read -r item; do
            FILE=$(echo "$item" | jq -r '.file')
            DEST=$(echo "$item" | jq -r '.dest')
            LINK_NAME=$(echo "$item" | jq -r '.name')
            EXECUTABLE=$(echo "$item" | jq -r '.executable // false')
            [ "$FILE" == "null" ] || [ "$DEST" == "null" ] || [ "$LINK_NAME" == "null" ] && continue

            DEST="${DEST/#\~/$HOME}"
            DEST="${DEST//\$HOME/$HOME}"
            mkdir -p "$DEST"
            TARGET_LINK="$DEST/$LINK_NAME"

            if [ -e "$TARGET_LINK" ] || [ -L "$TARGET_LINK" ]; then
                if [ -L "$TARGET_LINK" ] && [ "$(readlink "$TARGET_LINK")" == "$APP_DIR/$FILE" ]; then
                    echo -e "   ${YELLOW}[!] Enlace existente de la misma app: $LINK_NAME → se reemplazará.${NC}"
                    rm -f "$TARGET_LINK"
                else
                    ask_overwrite "$TARGET_LINK" "$PKG_NAME"
                fi
            fi

            ln -s "$APP_DIR/$FILE" "$TARGET_LINK"
            if [ "$EXECUTABLE" == "true" ]; then
                chmod +x "$APP_DIR/$FILE"
                echo -e "   [+] Enlazado (ejecutable): $LINK_NAME -> $DEST"
            else
                echo -e "   [+] Enlazado: $LINK_NAME -> $DEST"
            fi
        done < <(jq -c '.links[]' "$GUIDE_FILE")
    else
        echo -e "${YELLOW}Aviso: No se encontró $GUIDE_TARGET. No se crearon enlaces.${NC}"
    fi

    echo -e "${GREEN}¡$PKG_NAME instalado correctamente! (versión $REPO_VERSION)${NC}"
    return 0
}

# --- INICIO DEL SCRIPT (manejo de múltiples paquetes) ---
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}"
    exit 1
fi

AUTO_YES=0
DOWNLOAD_ONLY=0
USER_INSTALL=0
PACKAGES=()

# Recorrer argumentos separando opciones de paquetes
for arg in "$@"; do
    case "$arg" in
        -y) AUTO_YES=1 ;;
        -d) DOWNLOAD_ONLY=1 ;;
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

# Auto-actualización de Casata (solo si el primer paquete es "casata" y no hay más)
if [ ${#PACKAGES[@]} -eq 1 ] && [ "${PACKAGES[0]}" == "casata" ]; then
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}Actualizando Casata${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    [ "$EUID" -ne 0 ] && { echo -e "${RED}Requiere root.${NC}"; exit 1; }
    if [ $AUTO_YES -eq 0 ]; then
        read -p "¿Descargar última versión? [S/n] " resp < /dev/tty
        [[ "$resp" =~ ^[Nn] ]] && exit 0
    fi
    TEMP_DIR=$(mktemp -d)
    ZIP_URL="https://github.com/Monojo-Project/Casata/archive/refs/heads/main.zip"
    wget -q --show-progress -O "$TEMP_DIR/casata.zip" "$ZIP_URL" || exit 1
    unzip -q "$TEMP_DIR/casata.zip" -d "$TEMP_DIR"
    EXTRACTED=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "Casata-*" | head -1)
    cp -f "$EXTRACTED/usr/bin/casata" /usr/bin/casata
    chmod +x /usr/bin/casata
    rm -rf "$GLOBAL_ROOT/modules"
    cp -r "$EXTRACTED/usr/local/casata/modules" "$GLOBAL_ROOT/"
    chmod +x "$GLOBAL_ROOT"/modules/*.sh
    cp -f "$EXTRACTED/usr/local/casata/"{HELP,VERSION,WELCOME} "$GLOBAL_ROOT/" 2>/dev/null
    echo -e "${GREEN}Casata actualizado.${NC}"
    exit 0
fi

# Instalación normal de múltiples paquetes
FAILED=()
for PKG in "${PACKAGES[@]}"; do
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Instalando: $PKG${NC}"
    echo -e "${GREEN}========================================${NC}"
    if install_one "$PKG" "$AUTO_YES" "$DOWNLOAD_ONLY" "$USER_INSTALL"; then
        echo -e "${GREEN}✔ $PKG instalado correctamente.${NC}"
    else
        echo -e "${RED}✖ Falló la instalación de $PKG.${NC}"
        FAILED+=("$PKG")
    fi
done

echo -e "\n${GREEN}════════════════════════════════════════${NC}"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ Todos los paquetes se instalaron correctamente.${NC}"
else
    echo -e "${RED}✖ Los siguientes paquetes fallaron: ${FAILED[*]}${NC}"
fi
echo -e "${GREEN}════════════════════════════════════════${NC}"

if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
fi
exit 0
