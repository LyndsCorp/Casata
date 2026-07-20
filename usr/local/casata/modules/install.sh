#!/bin/bash

# /usr/local/casata/modules/install.sh
# Copyright (C) 2026, GPL v3+, Lynds Corp., Aros Legendarios, David Baña Szymaniak
# Script de instalar aplicaciones en Casata

shopt -s nullglob
set -euo pipefail

GLOBAL_ROOT="/usr/local/casata"
DATA_DIR="$GLOBAL_ROOT/data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

APT_UPDATE_STATUS=0

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

install_system_deps() {
    local deps="$1"

    echo -e "${YELLOW}Intentando instalar dependencias: $deps${NC}"

    # Si no tenemos apt, no hay nada que hacer
    if ! command -v apt &>/dev/null; then
        echo -e "${RED}Error: APT no está disponible.${NC}"
        return 1
    fi

    # Ejecutar apt update solo la primera vez
    if [ $APT_UPDATE_STATUS -eq 0 ]; then
        echo -e "${YELLOW}Ejecutando apt update...${NC}"
        if apt update; then
            APT_UPDATE_STATUS=1
        else
            APT_UPDATE_STATUS=2
            echo -e "${RED}ERROR DEL CLIENTE: apt update falló. No se instalarán dependencias del sistema.${NC}"
            return 1
        fi
    elif [ $APT_UPDATE_STATUS -eq 2 ]; then
        # Si la actualización falló antes, no intentamos instalar más paquetes
        echo -e "${RED}No se intenta instalar dependencias porque apt update falló.${NC}"
        return 1
    fi

    # Llegados aquí APT_UPDATE_STATUS es 1; ejecutar la instalación
    if apt install -y $deps; then
        return 0
    else
        echo -e "${RED}ERROR DE CLIENTE: No se pudieron instalar las dependencias automáticamente con APT. Por favor, instálalas manualmente: $deps${NC}"
        return 1
    fi
}

install_pip_deps() {
    local pkgs="$1"   # lista separada por saltos de línea
    local venv_path="/usr/local/casata/python-venv"
    local lock_file="$venv_path/.install.lock"
    
    # Crear venv si no existe (verificación con ls)
    if ! ls "$venv_path/bin/python" >/dev/null 2>&1; then
        echo -e "${YELLOW}Creando entorno virtual compartido en $venv_path...${NC}"
        if command -v python3 &>/dev/null; then
            python3 -m venv "$venv_path" || { echo -e "${RED}Error al crear venv.${NC}"; return 1; }
        else
            echo -e "${RED}Error: python3 no encontrado. No se pueden instalar dependencias pip.${NC}"
            return 1
        fi
    fi
    
    # Asegurar que el lock file existe
    touch "$lock_file" 2>/dev/null || { echo -e "${RED}Error: No se puede crear lock file en $lock_file.${NC}"; return 1; }
    
    # Convertir lista a array
    local pip_pkgs=()
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && pip_pkgs+=("$pkg")
    done <<< "$pkgs"
    
    if [ ${#pip_pkgs[@]} -eq 0 ]; then
        return 0
    fi
    
    echo -e "${YELLOW}Instalando dependencias Python: ${pip_pkgs[*]}${NC}"
    flock --exclusive "$lock_file" "$venv_path/bin/pip" install "${pip_pkgs[@]}" || {
        echo -e "${RED}Error al instalar dependencias pip.${NC}"
        return 1
    }
    return 0
}

force_remove() {
    local app_dir="$1"
    local guide_target="$2"
    echo -e "${YELLOW}Eliminando instalación anterior/revertiendo enlaces...${NC}"
    if [ -f "$app_dir/$guide_target" ]; then
        jq -c '.links[]' "$app_dir/$guide_target" 2>/dev/null | while read -r item; do
            DEST=$(echo "$item" | jq -r '.dest')
            LINK_NAME=$(echo "$item" | jq -r '.name')
            FILE=$(echo "$item" | jq -r '.file')
            [ "$DEST" == "null" ] || [ "$LINK_NAME" == "null" ] || [ "$FILE" == "null" ] && continue
            
            DEST="${DEST/#\~/$HOME}"
            DEST="${DEST//\$HOME/$HOME}"
            TARGET_LINK="$DEST/$LINK_NAME"
            
            if [ -L "$TARGET_LINK" ] && [ "$(readlink "$TARGET_LINK")" == "$app_dir/$FILE" ]; then
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
    local auto_yes="$3"

    if [ "$auto_yes" -eq 1 ]; then
        echo -e "${YELLOW}Usando -y: Sobrescribiendo '$target' automáticamente.${NC}"
        rm -rf "$target"
        return 0
    fi

    echo -e "${YELLOW}Advertencia: '$target' ya existe y no es un enlace a $app_name.${NC}"
    read -p "¿Sobrescribirlo? (perderás el archivo original) [s/N/a (abortar)]: " resp < /dev/tty
    if [[ "$resp" =~ ^[sSyY] ]]; then
        rm -rf "$target"
        echo -e "${GREEN}Archivo eliminado. Continuando...${NC}"
        return 0
    elif [[ "$resp" =~ ^[aA] ]]; then
        echo -e "${RED}Instalación abortada por el usuario.${NC}"
        exit 1
    else
        echo -e "${YELLOW}Omitiendo enlace. No se sobrescribirá.${NC}"
        return 1
    fi
}

# Función para instalar un solo paquete (siempre global)
install_one() {
    local PKG_NAME="$1"
    local AUTO_YES="$2"
    local DOWNLOAD_ONLY="$3"

    # Instalación exclusivamente global
    [ "$EUID" -ne 0 ] && { echo -e "${RED}Instalación global requiere root.${NC}"; return 1; }
    APPS_DIR="$GLOBAL_ROOT/apps"
    GUIDE_TARGET="GUIDE.json"

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

    # Leer metadatos (nuevo formato: apt y pip)
    REPO_VERSION=$(jq -r '.version // "0.0.0"' "$PKG_FILE")
    APT_DEPS=$(jq -r '.apt[]? // empty' "$PKG_FILE")
    PIP_DEPS=$(jq -r '.pip[]? // empty' "$PKG_FILE")

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

    # Gestión de dependencias APT
    if [ -n "$APT_DEPS" ]; then
        echo -e "\n${YELLOW}Dependencias del sistema para $PKG_NAME:${NC}"
        echo "$APT_DEPS" | sed 's/^/  • /'
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias del sistema.${NC}"
            else
                install_system_deps "$(echo "$APT_DEPS" | tr '\n' ' ')" || return 1
            fi
        else
            install_system_deps "$(echo "$APT_DEPS" | tr '\n' ' ')" || return 1
        fi
    fi

    # Gestión de dependencias pip
    if [ -n "$PIP_DEPS" ]; then
        echo -e "\n${YELLOW}Dependencias Python para $PKG_NAME:${NC}"
        echo "$PIP_DEPS" | sed 's/^/  • /'
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Python con pip? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias pip.${NC}"
            else
                install_pip_deps "$PIP_DEPS" || return 1
            fi
        else
            install_pip_deps "$PIP_DEPS" || return 1
        fi
    fi

    # Eliminación segura (solo si las dependencias no cancelaron)
    if [ $NEED_UPDATE -eq 1 ] || [ $NEED_UPDATE -eq 2 ]; then
        echo -e "${YELLOW}Preparando actualización/reinstalación...${NC}"
        force_remove "$APP_DIR" "$GUIDE_TARGET"
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
                    if ! ask_overwrite "$TARGET_LINK" "$PKG_NAME" "$AUTO_YES"; then
                        continue
                    fi
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

# --- INICIO DEL SCRIPT (manejo de argumentos y router) ---
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}"
    exit 1
fi

AUTO_YES=0
DOWNLOAD_ONLY=0
PACKAGES=()

for arg in "$@"; do
    case "$arg" in
        -y) AUTO_YES=1 ;;
        -d) DOWNLOAD_ONLY=1 ;;
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

# --- ROUTER: si el único paquete es "casata", delegamos en el nuevo módulo ---
if [ ${#PACKAGES[@]} -eq 1 ] && [ "${PACKAGES[0]}" == "casata" ]; then
    echo -e "${GREEN}Redirigiendo a la actualización de Casata...${NC}"
    exec "$GLOBAL_ROOT/modules/install-casata.sh" "$@"
    # Si exec falla:
    echo -e "${RED}Error: No se pudo ejecutar el módulo de actualización de Casata.${NC}"
    exit 1
fi

# --- Instalación normal de aplicaciones ---
FAILED=()
for PKG in "${PACKAGES[@]}"; do
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Instalando: $PKG${NC}"
    echo -e "${GREEN}========================================${NC}"
    if install_one "$PKG" "$AUTO_YES" "$DOWNLOAD_ONLY"; then
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
