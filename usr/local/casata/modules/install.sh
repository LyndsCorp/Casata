#!/bin/bash
# /usr/local/casata/modules/install.sh - con preguntas reales al usuario

shopt -s nullglob
set -euo pipefail

GLOBAL_ROOT="/usr/local/casata"
DATA_DIR="$GLOBAL_ROOT/data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Variables para limpieza
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

# Detectar gestor de paquetes
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
        apt) apt update && apt install $deps ;;
        dnf|yum) $pkg_manager install -y $deps ;;
        pacman) pacman -S --noconfirm $deps ;;
        zypper) zypper install -y $deps ;;
    esac
}

# Función para eliminar una instalación existente (sin preguntar)
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

# Función para preguntar y eliminar un archivo que bloquea
ask_overwrite() {
    local target="$1"
    local app_name="$2"
    echo -e "${YELLOW}Advertencia: '$target' ya existe y no es un enlace a $app_name.${NC}"
    # Leer desde el terminal directamente, no desde la entrada estándar del bucle
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

# --- INICIO DEL SCRIPT ---
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}"
    exit 1
fi

AUTO_YES=0
DOWNLOAD_ONLY=0
USER_INSTALL=0
PKG_NAME=""

for arg in "$@"; do
    case "$arg" in
        -y) AUTO_YES=1 ;;
        -d) DOWNLOAD_ONLY=1 ;;
        --user) USER_INSTALL=1 ;;
        *) PKG_NAME=$arg ;;
    esac
done

[ -z "$PKG_NAME" ] && { echo -e "${RED}Error: Falta el nombre del paquete.${NC}"; exit 1; }

# Auto-actualización de Casata
if [ "$PKG_NAME" == "casata" ]; then
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

# Configuración de rutas según modo
if [ $USER_INSTALL -eq 1 ]; then
    APPS_DIR="$HOME/.local/casata/apps"
    GUIDE_TARGET="GUIDE-USER.json"
    INSTALL_TYPE="Usuario"
else
    [ "$EUID" -ne 0 ] && { echo -e "${RED}Instalación global requiere root.${NC}"; exit 1; }
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
    exit 1
fi

DOWNLOAD_URL=$(jq -r '.download_url // empty' "$SINGREPO_FILE")
[ -z "$DOWNLOAD_URL" ] && { echo -e "${RED}Error: No hay download_url en el singrepo.${NC}"; exit 1; }

PKG_FILE="$DATA_DIR/${PKG_NAME}.json"
[ ! -f "$PKG_FILE" ] && { echo -e "${RED}Error: Base de datos local no encontrada. Ejecute 'casata update' primero.${NC}"; exit 1; }

# Leer metadatos del repositorio
REPO_VERSION=$(jq -r '.version // "0.0.0"' "$PKG_FILE")
REPO_DESC=$(jq -r '.description // ""' "$PKG_FILE")
REPO_DEPS=$(jq -r '.dependencies[]? // empty' "$PKG_FILE")

# --- COMPROBAR SI YA ESTÁ INSTALADO Y COMPARAR VERSIONES ---
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
                [[ ! "$rein" =~ ^[sSyY] ]] && exit 0
                NEED_UPDATE=2
            else
                echo -e "${YELLOW}Usando -y: se reinstalará.${NC}"
                NEED_UPDATE=2
            fi
        else
            echo -e "${GREEN}La versión instalada es más reciente que la del repositorio. No se hará nada.${NC}"
            exit 0
        fi
    else
        echo -e "${YELLOW}Paquete instalado pero sin archivo VERSION. Se reinstalará.${NC}"
        NEED_UPDATE=2
    fi
fi

# Si se necesita actualizar o reinstalar, eliminar la instalación anterior
if [ $NEED_UPDATE -eq 1 ] || [ $NEED_UPDATE -eq 2 ]; then
    echo -e "${YELLOW}Preparando actualización/reinstalación...${NC}"
    force_remove "$APP_DIR" "$GUIDE_TARGET"
fi

# --- GESTIÓN DE DEPENDENCIAS ---
if [ -n "$REPO_DEPS" ]; then
    echo -e "\n${YELLOW}Dependencias:${NC}"
    echo "$REPO_DEPS" | sed 's/^/  • /'
    if [ $AUTO_YES -eq 0 ]; then
        read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
        [[ "$resp" =~ ^[Nn] ]] && { echo "Instalación abortada."; exit 0; }
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
            [[ ! "$resp" =~ ^[Ss] ]] && exit 1
        fi
    else
        install_system_deps "$(echo "$REPO_DEPS" | tr '\n' ' ')" || exit 1
    fi
fi

# --- DESCARGA Y EXTRACCIÓN ---
mkdir -p "$APP_DIR"
ARCHIVE_NAME=$(basename "$DOWNLOAD_URL" | cut -d '?' -f1)
ARCHIVE_PATH="$APP_DIR/$ARCHIVE_NAME"
EXTRACT_DIR=$(mktemp -d)

echo -e "${GREEN}Descargando...${NC}"
wget -q --show-progress -O "$ARCHIVE_PATH" "$DOWNLOAD_URL" || { echo -e "${RED}Error descarga.${NC}"; exit 1; }

case "$ARCHIVE_NAME" in
    *.zip) unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR" ;;
    *.tar.gz|*.tgz) tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" ;;
    *.tar.xz) tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" ;;
    *) echo -e "${RED}Formato no soportado.${NC}"; exit 1 ;;
esac

# Buscar directorio raíz (puede contener VERSION)
SRC_DIR=$(find "$EXTRACT_DIR" -name "VERSION" -exec dirname {} \; | head -1)
[ -z "$SRC_DIR" ] && SRC_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -z "$SRC_DIR" ] && SRC_DIR="$EXTRACT_DIR"

mv "$SRC_DIR"/* "$APP_DIR/" 2>/dev/null || mv "$SRC_DIR"/.??* "$APP_DIR/" 2>/dev/null || true
rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
EXTRACT_DIR=""  # ya no es necesario limpiar

[ $DOWNLOAD_ONLY -eq 1 ] && { echo -e "${YELLOW}Descargado en $APP_DIR (sin enlaces).${NC}"; exit 0; }

# --- CREAR ENLACES SIMBÓLICOS CON VERIFICACIÓN DE SEGURIDAD Y PREGUNTA ---
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
                # Enlace válido de la misma app -> lo eliminamos para recrearlo
                echo -e "   ${YELLOW}[!] Enlace existente de la misma app: $LINK_NAME → se reemplazará.${NC}"
                rm -f "$TARGET_LINK"
            else
                # Algo existe que no es un enlace a esta app -> preguntar
                ask_overwrite "$TARGET_LINK" "$PKG_NAME"
            fi
        fi

        # Crear el enlace
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

echo -e "\n${GREEN}¡$PKG_NAME instalado correctamente! (versión $REPO_VERSION)${NC}"
