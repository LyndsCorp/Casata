#!/bin/bash

# /usr/local/casata/modules/install.sh
# Copyright (C) 2026 David Baña Szymaniak
# GPL v3 License
# Script de instalar aplicaciones en Casata

shopt -s nullglob
set -euo pipefail

GLOBAL_ROOT="/usr/local/casata"
DATA_DIR="$GLOBAL_ROOT/data"
SINGREPOS_PRIORITY="$GLOBAL_ROOT/repos/singrepos/PRIORITY"
OS_PACKAGES_FILE="$GLOBAL_ROOT/OS_PACKAGES"
CASATA_DEP_CACHE="/tmp/casata-deps-$$"

# ------------------------------------------------------------
# Variables de control para instalación por lotes
# ------------------------------------------------------------
SKIP_SYSTEM_DEPS=0
SKIP_PIP_DEPS=0
SKIP_CASATA_DEPS=0

declare -A COLLECTED_APT=()
declare -A COLLECTED_PACMAN=()
declare -A COLLECTED_DNF=()
declare -A COLLECTED_PIP=()
declare -A COLLECTED_CASATA=()
declare -A VISITED_PACKAGES=()
declare -A IN_STACK=()
declare -a CASATA_ORDER=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ------------------------------------------------------------
# Función para resolver versiones que pueden ser URLs
# ------------------------------------------------------------
resolve_version() {
    local version_input="$1"
    if [[ "$version_input" =~ ^[Hh][Tt][Tt][Pp] ]]; then
        local temp_file=$(mktemp)
        if wget -q --timeout=10 --tries=1 -O "$temp_file" "$version_input" 2>/dev/null; then
            local resolved=$(cat "$temp_file" | tr -d '[:space:]')
            rm -f "$temp_file"
            if [ -n "$resolved" ]; then
                echo "$resolved"
            else
                rm -f "$temp_file"
                echo -e "${RED}Error: La URL de versión devolvió contenido vacío.${NC}" >&2
                return 1
            fi
        else
            rm -f "$temp_file"
            echo -e "${RED}Error: No se pudo descargar la versión desde $version_input.${NC}" >&2
            return 1
        fi
    else
        echo "$version_input"
    fi
}

# ------------------------------------------------------------
# Estado del gestor de paquetes
# ------------------------------------------------------------
PKG_MANAGER=""
PM_UPDATE_DONE=0

# ------------------------------------------------------------
# Directorios y archivos protegidos
# ------------------------------------------------------------
SAVE_FILES_FILE="$GLOBAL_ROOT/SAVE_FILES.txt"
PROTECTED_DIRS=()
PROTECTED_FILES=()

# ------------------------------------------------------------
# Función auxiliar: resolver ruta canónica (con fallback)
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
# Carga de rutas protegidas desde archivo externo
# ------------------------------------------------------------
load_protected_paths() {
    if [ ! -f "$SAVE_FILES_FILE" ]; then
        echo -e "${RED}Error: Archivo de protección no encontrado: $SAVE_FILES_FILE${NC}" >&2
        exit 1
    fi

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == */ ]]; then
            PROTECTED_DIRS+=("$(canonical_path "${line%/}")")
        else
            PROTECTED_FILES+=("$(canonical_path "$line")")
        fi
    done < "$SAVE_FILES_FILE"
}

# ------------------------------------------------------------
# Borrado seguro de directorios dentro de $GLOBAL_ROOT/apps
# ------------------------------------------------------------
safe_rm_rf() {
    local path="$1"

    [ -n "$path" ] || return 1
    [ "$path" != "/" ] || return 1
    [ "$path" != "$GLOBAL_ROOT" ] || return 1
    [[ "$path" == "$GLOBAL_ROOT/apps/"* ]] || return 1

    rm -rf -- "$path"
}

cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    if [ -n "${EXTRACT_DIR:-}" ] && [ -d "$EXTRACT_DIR" ]; then
        rm -rf "$EXTRACT_DIR"
    fi
    rm -f "$CASATA_DEP_CACHE"
}
trap cleanup EXIT

# ------------------------------------------------------------
# Detección del gestor de paquetes
# ------------------------------------------------------------
detect_package_manager() {
    if [ -x /usr/bin/apt ]; then
        echo "apt"
    elif [ -x /usr/bin/pacman ]; then
        echo "pacman"
    elif [ -x /usr/bin/dnf ]; then
        echo "dnf"
    else
        echo ""
    fi
}

save_os_packages() {
    local manager="$1"
    echo "$manager" > "$OS_PACKAGES_FILE"
    echo -e "${YELLOW}OS_PACKAGES actualizado con: $manager${NC}"
}

init_package_manager() {
    if [ -f "$OS_PACKAGES_FILE" ]; then
        local saved
        saved=$(cat "$OS_PACKAGES_FILE" | tr -d '[:space:]')
        if [[ "$saved" == "apt" || "$saved" == "pacman" || "$saved" == "dnf" ]]; then
            PKG_MANAGER="$saved"
            echo -e "${GREEN}Usando gestor de paquetes de tu sistema operativo: $PKG_MANAGER${NC}"
            if ! command -v "$PKG_MANAGER" &>/dev/null; then
                echo -e "${YELLOW}El gestor '$PKG_MANAGER' no está presente. Redetectando...${NC}"
                local detected
                detected=$(detect_package_manager)
                if [ -z "$detected" ]; then
                    echo -e "${RED}No se encontró ningún gestor de paquetes compatible (apt, pacman, dnf).${NC}"
                    exit 1
                fi
                PKG_MANAGER="$detected"
                save_os_packages "$PKG_MANAGER"
            fi
            return
        fi
    fi

    local detected
    detected=$(detect_package_manager)
    if [ -z "$detected" ]; then
        echo -e "${RED}No se encontró ningún gestor de paquetes compatible (apt, pacman, dnf).${NC}"
        exit 1
    fi
    PKG_MANAGER="$detected"
    save_os_packages "$PKG_MANAGER"
}

# ------------------------------------------------------------
# Convertir string multilínea a array
# ------------------------------------------------------------
split_to_array() {
    local -n arr_ref="$1"
    local input="$2"
    arr_ref=()
    while IFS= read -r line; do
        [ -n "$line" ] && arr_ref+=("$line")
    done <<< "$input"
}

# ------------------------------------------------------------
# Normalizar nombre de paquete
# ------------------------------------------------------------
normalize_pkg_name() {
    local name="$1"
    name="${name%.casata}"
    name="${name%.tar.gz}"
    name="${name%.tgz}"
    name="${name%.tar.xz}"
    name="${name%.zip}"
    name="${name%.tar}"
    name="${name,,}"
    echo "$name"
}

# ------------------------------------------------------------
# Comprobar si un archivo tiene extensión de paquete válida
# ------------------------------------------------------------
is_valid_package_file() {
    local file="$1"
    local base
    base=$(basename "$file")
    [[ "$base" == *.casata || "$base" == *.zip || "$base" == *.tar.gz || "$base" == *.tgz || "$base" == *.tar.xz || "$base" == *.tar ]]
}

# ------------------------------------------------------------
# Instalación de dependencias del sistema (usando arrays)
# ------------------------------------------------------------
install_system_deps() {
    local -n deps_array="$1"
    [ ${#deps_array[@]} -eq 0 ] && return 0

    echo -e "${YELLOW}Intentando instalar dependencias del sistema ($PKG_MANAGER): ${deps_array[*]}${NC}"

    _try_install() {
        case "$PKG_MANAGER" in
            apt)
                if [ $PM_UPDATE_DONE -eq 0 ]; then
                    echo -e "${YELLOW}Ejecutando apt update...${NC}"
                    if apt update; then
                        PM_UPDATE_DONE=1
                    else
                        PM_UPDATE_DONE=2
                        echo -e "${RED}ERROR: apt update falló.${NC}"
                        return 1
                    fi
                elif [ $PM_UPDATE_DONE -eq 2 ]; then
                    echo -e "${RED}No se intenta instalar porque apt update falló previamente.${NC}"
                    return 1
                fi

                if [ "${AUTO_YES:-0}" -eq 1 ]; then
                    apt install -y "${deps_array[@]}"
                else
                    apt install "${deps_array[@]}"
                fi
                ;;
            pacman)
                if [ "${AUTO_YES:-0}" -eq 1 ]; then
                    pacman -S --needed --noconfirm "${deps_array[@]}" && return 0
                else
                    pacman -S --needed "${deps_array[@]}" && return 0
                fi

                echo -e "${YELLOW}No se encontraron los paquetes. Es posible que necesites actualizar tu sistema con 'pacman -Syu'.${NC}"
                echo -e "${YELLOW}Casata no ejecutará 'pacman -Sy' para evitar actualizaciones parciales.${NC}"
                if [ "${AUTO_YES:-0}" -eq 1 ]; then
                    echo -e "${RED}Error: No se pudieron instalar las dependencias.${NC}"
                    return 1
                else
                    read -p "¿Deseas ejecutar 'pacman -Syu' (actualización completa) e intentar de nuevo? [s/N] " resp < /dev/tty
                    if [[ "$resp" =~ ^[sSyY] ]]; then
                        if pacman -Syu --noconfirm; then
                            PM_UPDATE_DONE=1
                            pacman -S --needed "${deps_array[@]}"
                        else
                            PM_UPDATE_DONE=2
                            echo -e "${RED}ERROR: pacman -Syu falló.${NC}"
                            return 1
                        fi
                    else
                        echo -e "${YELLOW}Omitiendo dependencias del sistema.${NC}"
                        return 1
                    fi
                fi
                ;;
            dnf)
                if [ $PM_UPDATE_DONE -eq 0 ]; then
                    echo -e "${YELLOW}Ejecutando dnf makecache...${NC}"
                    if dnf makecache; then
                        PM_UPDATE_DONE=1
                    else
                        PM_UPDATE_DONE=2
                        echo -e "${RED}ERROR: dnf makecache falló.${NC}"
                        return 1
                    fi
                elif [ $PM_UPDATE_DONE -eq 2 ]; then
                    echo -e "${RED}No se intenta instalar porque dnf makecache falló.${NC}"
                    return 1
                fi

                if [ "${AUTO_YES:-0}" -eq 1 ]; then
                    dnf install -y "${deps_array[@]}"
                else
                    dnf install "${deps_array[@]}"
                fi
                ;;
            *)
                echo -e "${RED}Gestor de paquetes no soportado: $PKG_MANAGER${NC}"
                return 1
                ;;
        esac
    }

    if ! _try_install; then
        if ! command -v "$PKG_MANAGER" &>/dev/null; then
            echo -e "${YELLOW}El gestor '$PKG_MANAGER' parece no estar disponible. Redetectando...${NC}"
            local detected
            detected=$(detect_package_manager)
            if [ -z "$detected" ]; then
                echo -e "${RED}No se encontró ningún gestor de paquetes compatible.${NC}"
                return 1
            fi
            PKG_MANAGER="$detected"
            save_os_packages "$PKG_MANAGER"
            PM_UPDATE_DONE=0
            echo -e "${YELLOW}Reintentando con el gestor $PKG_MANAGER...${NC}"
            _try_install || {
                echo -e "${RED}Error al instalar dependencias con el nuevo gestor.${NC}"
                return 1
            }
        else
            echo -e "${RED}Error al instalar dependencias con $PKG_MANAGER.${NC}"
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------
# Instalación de dependencias pip
# ------------------------------------------------------------
install_pip_deps() {
    local -n pkgs_ref="$1"
    [ ${#pkgs_ref[@]} -eq 0 ] && return 0

    local venv_path="/usr/local/casata/python-venv"
    local lock_file="$venv_path/.install.lock"

    if [ ! -x "$venv_path/bin/python" ]; then
        echo -e "${YELLOW}Creando entorno virtual compartido en $venv_path...${NC}"
        if command -v python3 &>/dev/null; then
            python3 -m venv "$venv_path" || { echo -e "${RED}Error al crear venv.${NC}"; return 1; }
        else
            echo -e "${RED}Error: python3 no encontrado.${NC}"
            return 1
        fi
    fi

    if ! command -v flock &>/dev/null; then
        echo -e "${RED}Error: 'flock' no está disponible. Es necesario para la instalación segura de paquetes pip.${NC}"
        return 1
    fi

    touch "$lock_file" 2>/dev/null || { echo -e "${RED}Error: No se puede crear lock file.${NC}"; return 1; }

    echo -e "${YELLOW}Instalando dependencias Python: ${pkgs_ref[*]}${NC}"
    flock --exclusive "$lock_file" "$venv_path/bin/pip" install "${pkgs_ref[@]}" || {
        echo -e "${RED}Error al instalar dependencias pip.${NC}"
        return 1
    }
    return 0
}

# ------------------------------------------------------------
# Instalación de dependencias Casata (con caché de dependencias)
# ------------------------------------------------------------
install_casata_deps() {
    local -n casata_array="$1"
    local auto_yes="${2:-0}"

    [ ${#casata_array[@]} -eq 0 ] && return 0

    if [ ! -f "$CASATA_DEP_CACHE" ]; then
        touch "$CASATA_DEP_CACHE"
    fi

    echo -e "${YELLOW}Instalando dependencias Casata: ${casata_array[*]}${NC}"

    for pkg in "${casata_array[@]}"; do
        [ -z "$pkg" ] && continue

        local normalized_pkg
        normalized_pkg=$(normalize_pkg_name "$pkg")
        [ -z "$normalized_pkg" ] && continue

        if grep -qxF "$normalized_pkg" "$CASATA_DEP_CACHE"; then
            echo -e "${YELLOW}→ Dependencia Casata '$normalized_pkg' ya fue procesada, omitiendo.${NC}"
            continue
        fi

        echo "$normalized_pkg" >> "$CASATA_DEP_CACHE"

        echo -e "${YELLOW}→ Instalando dependencia Casata: $normalized_pkg${NC}"

        if [ "$auto_yes" -eq 1 ]; then
            "$GLOBAL_ROOT/modules/install.sh" -y "$normalized_pkg"
        else
            "$GLOBAL_ROOT/modules/install.sh" "$normalized_pkg"
        fi || {
            echo -e "${RED}Error al instalar la dependencia Casata '$normalized_pkg'.${NC}"
            return 1
        }
    done

    return 0
}

# ------------------------------------------------------------
# Recopilación recursiva de dependencias con detección de ciclos
# ------------------------------------------------------------
collect_package_deps() {
    local pkg="$1"
    pkg=$(normalize_pkg_name "$pkg")

    if [ "${IN_STACK[$pkg]:-0}" -eq 1 ]; then
        echo -e "${RED}Error: Ciclo de dependencias detectado en '$pkg'.${NC}" >&2
        return 1
    fi

    if [ "${VISITED_PACKAGES[$pkg]:-0}" -eq 1 ]; then
        return 0
    fi

    local pkg_file="$DATA_DIR/${pkg}.json"
    if [ ! -f "$pkg_file" ]; then
        echo -e "${RED}Error: Dependencia '$pkg' no encontrada en la base de datos local. Ejecute 'casata update'.${NC}" >&2
        return 1
    fi

    IN_STACK[$pkg]=1
    VISITED_PACKAGES[$pkg]=1

    local dep

    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_APT["$dep"]=1
    done < <(jq -r '.apt? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_PACMAN["$dep"]=1
    done < <(jq -r '.pacman? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_DNF["$dep"]=1
    done < <(jq -r '.dnf? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_PIP["$dep"]=1
    done < <(jq -r '.pip? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    while IFS= read -r dep; do
        [ -n "$dep" ] || continue

        dep=$(normalize_pkg_name "$dep")

        if [ "${IN_STACK[$dep]:-0}" -eq 1 ]; then
            echo -e "${RED}Error: Ciclo de dependencias detectado: '$pkg' -> '$dep'.${NC}" >&2
            return 1
        fi

        if [ "${VISITED_PACKAGES[$dep]:-0}" -eq 0 ]; then
            COLLECTED_CASATA["$dep"]=1
            collect_package_deps "$dep" || return 1
            CASATA_ORDER+=("$dep")
        else
            COLLECTED_CASATA["$dep"]=1
        fi
    done < <(jq -r '.casata? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    IN_STACK[$pkg]=0
}

# ------------------------------------------------------------
# Eliminación forzada y reversión de enlaces
# ------------------------------------------------------------
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
    safe_rm_rf "$app_dir"
}

ask_overwrite() {
    local target="$1"
    local app_name="$2"
    local auto_yes="$3"

    if [ "$auto_yes" -eq 1 ]; then
        if [ -L "$target" ] || [ -f "$target" ]; then
            rm -f -- "$target"
            return 0
        else
            echo -e "${RED}Error: '$target' es un directorio y no se puede sobrescribir.${NC}"
            return 1
        fi
    fi

    echo -e "${YELLOW}Advertencia: '$target' ya existe y no es un enlace a $app_name.${NC}"
    read -p "¿Sobrescribirlo? (perderás el archivo original) [s/N/a (abortar)]: " resp < /dev/tty
    if [[ "$resp" =~ ^[sSyY] ]]; then
        if [ -L "$target" ] || [ -f "$target" ]; then
            rm -f -- "$target"
            echo -e "${GREEN}Archivo eliminado. Continuando...${NC}"
            return 0
        else
            echo -e "${RED}Error: '$target' es un directorio y no se puede sobrescribir.${NC}"
            return 1
        fi
    elif [[ "$resp" =~ ^[aA] ]]; then
        echo -e "${RED}Instalación abortada por el usuario.${NC}"
        exit 1
    else
        echo -e "${YELLOW}Omitiendo enlace. No se sobrescribirá.${NC}"
        return 1
    fi
}

# ------------------------------------------------------------
# Extraer archivo descargado o local
# ------------------------------------------------------------
extract_archive() {
    local archive_path="$1"
    local extract_dir="$2"
    local base_name

    base_name=$(basename "$archive_path")
    if [[ "$base_name" == *.casata ]]; then
        base_name="${base_name%.casata}"
    fi

    case "$base_name" in
        *.zip) unzip -q "$archive_path" -d "$extract_dir" ;;
        *.tar.gz|*.tgz) tar -xzf "$archive_path" -C "$extract_dir" ;;
        *.tar.xz) tar -xJf "$archive_path" -C "$extract_dir" ;;
        *.tar) tar -xf "$archive_path" -C "$extract_dir" ;;
        *) echo -e "${RED}Formato de archivo no soportado.${NC}"; return 1 ;;
    esac

    SRC_DIR=$(find "$extract_dir" -name "VERSION" -exec dirname {} \; | head -1)
    [ -z "$SRC_DIR" ] && SRC_DIR=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -z "$SRC_DIR" ] && SRC_DIR="$extract_dir"
    return 0
}

# ------------------------------------------------------------
# Crear enlaces simbólicos según GUIDE.json con protecciones
# ------------------------------------------------------------
create_symlinks() {
    local app_dir="$1"
    local guide_target="$2"
    local pkg_name="$3"
    local auto_yes="$4"

    local guide_file="$app_dir/$guide_target"
    if [ ! -f "$guide_file" ]; then
        echo -e "${YELLOW}Aviso: No se encontró $guide_target. No se crearon enlaces.${NC}"
        return 0
    fi

    echo -e "${YELLOW}Configurando enlaces...${NC}"
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

        real_target=$(canonical_path "$TARGET_LINK")
        link_dir=$(dirname "$TARGET_LINK")
        real_dir=$(canonical_path "$link_dir")

        skip=false
        for protected in "${PROTECTED_DIRS[@]}"; do
            if [ "$real_dir" = "$protected" ] || [[ "$real_dir" == "$protected/"* ]]; then
                echo -e "${RED}🚫  Error de seguridad: No se permite crear enlaces en '$link_dir' (directorio protegido). Enlace '$LINK_NAME' omitido.${NC}"
                skip=true
                break
            fi
        done
        $skip && continue

        for protected in "${PROTECTED_FILES[@]}"; do
            if [ "$real_target" = "$protected" ]; then
                echo -e "${RED}🚫  Error de seguridad: No se permite sobrescribir el archivo protegido '$protected'. Enlace '$LINK_NAME' omitido.${NC}"
                skip=true
                break
            fi
        done
        $skip && continue

        if [ -e "$TARGET_LINK" ] || [ -L "$TARGET_LINK" ]; then
            if [ -L "$TARGET_LINK" ] && [ "$(readlink "$TARGET_LINK")" == "$app_dir/$FILE" ]; then
                echo -e "   ${YELLOW}[!] Enlace existente de la misma app: $LINK_NAME → se reemplazará.${NC}"
                rm -f "$TARGET_LINK"
            else
                if ! ask_overwrite "$TARGET_LINK" "$pkg_name" "$auto_yes"; then
                    continue
                fi
            fi
        fi

        ln -s "$app_dir/$FILE" "$TARGET_LINK"
        if [ "$EXECUTABLE" == "true" ]; then
            chmod +x "$app_dir/$FILE"
            echo -e "   [+] Enlazado (ejecutable): $LINK_NAME -> $DEST"
        else
            echo -e "   [+] Enlazado: $LINK_NAME -> $DEST"
        fi
    done < <(jq -c '.links[]' "$guide_file")
}

# ------------------------------------------------------------
# Ejecutar GUIDE.sh si el paquete está en la lista prioritaria
# ------------------------------------------------------------
maybe_run_guide() {
    local pkg_name="$1"
    local app_dir="$2"
    local auto_yes="$3"
    local repo_version="$4"

    if [ -f "$SINGREPOS_PRIORITY" ] && grep -qxF "$pkg_name" "$SINGREPOS_PRIORITY" 2>/dev/null; then
        echo -e "\n${YELLOW}Este paquete puede modificar archivos del sistema.${NC}"
        echo -e "\nRepositorio autorizado:"
        echo -e "  ${GREEN}$pkg_name${NC}"
        echo ""
        if [ $auto_yes -eq 1 ]; then
            echo -e "${YELLOW}Usando -y: se ejecutará GUIDE.sh automáticamente.${NC}"
        else
            read -p "¿Continuar? (S/n): " resp < /dev/tty
            if [[ ! "$resp" =~ ^[SsYy]?$ ]]; then
                echo -e "${YELLOW}Modificaciones del sistema omitidas. Puede ejecutar manualmente GUIDE.sh desde $app_dir.${NC}"
                echo -e "${GREEN}¡$pkg_name instalado correctamente! (versión $repo_version)${NC}"
                return 0
            fi
        fi

        local guide_script="$app_dir/GUIDE.sh"
        if [ -f "$guide_script" ]; then
            echo -e "${YELLOW}Ejecutando GUIDE.sh...${NC}"
            if bash "$guide_script"; then
                echo -e "${GREEN}✓ GUIDE.sh ejecutado correctamente.${NC}"
            else
                echo -e "${RED}Error al ejecutar GUIDE.sh. La instalación puede estar incompleta.${NC}"
                return 1
            fi
        else
            echo -e "${RED}Error: No se encontró GUIDE.sh en el paquete.${NC}"
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------
# Comprobación de versión y posible actualización
# ------------------------------------------------------------
version_check() {
    local app_dir="$1"
    local pkg_name="$2"
    local repo_version="$3"
    local auto_yes="$4"

    # repo_version ya viene resuelta (si era URL, ya se descargó)
    if [ -z "$repo_version" ]; then
        echo -e "${YELLOW}Advertencia: No se pudo determinar la versión del paquete. Se asume 0.0.0.${NC}"
        repo_version="0.0.0"
    fi

    if [ -d "$app_dir" ]; then
        if [ -f "$app_dir/VERSION" ]; then
            local installed_version
            # Versión instalada: se lee directamente del archivo VERSION (nunca es URL)
            installed_version=$(cat "$app_dir/VERSION" 2>/dev/null || echo "0.0.0")
            echo -e "${YELLOW}Versión instalada: $installed_version${NC}"
            echo -e "${YELLOW}Versión de remota: $repo_version${NC}"

            if [ "$installed_version" != "$repo_version" ]; then
                echo -e "${GREEN}Hay una actualización disponible.${NC}"
                return 0
            else
                echo -e "${GREEN}Ya tienes la última versión.${NC}"
                if [ $auto_yes -eq 0 ]; then
                    read -p "¿Reinstalar igualmente? [s/N] " rein < /dev/tty
                    [[ ! "$rein" =~ ^[sSyY] ]] && return 1
                else
                    echo -e "${YELLOW}Usando -y: se reinstalará.${NC}"
                fi
                return 0
            fi
        else
            echo -e "${YELLOW}Paquete instalado pero sin archivo VERSION. Se reinstalará.${NC}"
            return 0
        fi
    fi
    return 0
}

# ------------------------------------------------------------
# Instalación desde repositorio
# ------------------------------------------------------------
install_one() {
    local PKG_NAME="$1"
    local AUTO_YES="$2"

    [ "$EUID" -ne 0 ] && { echo -e "${RED}Instalación global requiere root.${NC}"; return 1; }
    APPS_DIR="$GLOBAL_ROOT/apps"
    GUIDE_TARGET="GUIDE.json"

    mkdir -p "$APPS_DIR"
    APP_DIR="$APPS_DIR/${PKG_NAME}"

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

    REPO_VERSION=$(jq -r '.version // "0.0.0"' "$PKG_FILE")
    # El campo version de metadatos puede ser URL, resolver
    if ! REPO_VERSION=$(resolve_version "$REPO_VERSION"); then
        REPO_VERSION="0.0.0"
        echo -e "${YELLOW}No se pudo resolver la versión del repositorio; se asume 0.0.0.${NC}"
    fi
    SHA256=$(jq -r '.sha256 // empty' "$PKG_FILE")

    # Leer dependencias en arrays
    local -a APT_DEPS=() PACMAN_DEPS=() DNF_DEPS=() PIP_DEPS=() CASATA_DEPS=()
    split_to_array APT_DEPS "$(jq -r '.apt? // [] | .[]' "$PKG_FILE")"
    split_to_array PACMAN_DEPS "$(jq -r '.pacman? // [] | .[]' "$PKG_FILE")"
    split_to_array DNF_DEPS "$(jq -r '.dnf? // [] | .[]' "$PKG_FILE")"
    split_to_array PIP_DEPS "$(jq -r '.pip? // [] | .[]' "$PKG_FILE")"
    split_to_array CASATA_DEPS "$(jq -r '.casata? // [] | .[]' "$PKG_FILE")"

    # ---------------------------
    # Version check ANTES de dependencias
    # ---------------------------
    if ! version_check "$APP_DIR" "$PKG_NAME" "$REPO_VERSION" "$AUTO_YES"; then
        return 2
    fi

    # ---------------------------
    # Dependencias
    # ---------------------------
    if [ "${SKIP_SYSTEM_DEPS:-0}" -eq 0 ]; then
        local -a SYSTEM_DEPS=()
        case "$PKG_MANAGER" in
            apt)    SYSTEM_DEPS=("${APT_DEPS[@]}") ;;
            pacman) SYSTEM_DEPS=("${PACMAN_DEPS[@]}") ;;
            dnf)    SYSTEM_DEPS=("${DNF_DEPS[@]}") ;;
        esac

        if [ ${#SYSTEM_DEPS[@]} -gt 0 ]; then
            echo -e "\n${YELLOW}Dependencias del sistema ($PKG_MANAGER) para $PKG_NAME:${NC}"
            printf '  • %s\n' "${SYSTEM_DEPS[@]}"
            if [ $AUTO_YES -eq 0 ]; then
                read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
                if [[ "$resp" =~ ^[Nn] ]]; then
                    echo -e "${YELLOW}Se omitió la instalación de dependencias del sistema.${NC}"
                else
                    install_system_deps SYSTEM_DEPS || return 1
                fi
            else
                install_system_deps SYSTEM_DEPS || return 1
            fi
        fi
    fi

    if [ "${SKIP_PIP_DEPS:-0}" -eq 0 ] && [ ${#PIP_DEPS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Dependencias Python para $PKG_NAME:${NC}"
        printf '  • %s\n' "${PIP_DEPS[@]}"
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Python con pip? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias pip.${NC}"
            else
                install_pip_deps PIP_DEPS || return 1
            fi
        else
            install_pip_deps PIP_DEPS || return 1
        fi
    fi

    if [ "${SKIP_CASATA_DEPS:-0}" -eq 0 ] && [ ${#CASATA_DEPS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Dependencias Casata para $PKG_NAME:${NC}"
        printf '  • %s\n' "${CASATA_DEPS[@]}"
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Casata? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias Casata.${NC}"
            else
                install_casata_deps CASATA_DEPS "$AUTO_YES" || return 1
            fi
        else
            install_casata_deps CASATA_DEPS "$AUTO_YES" || return 1
        fi
    fi

    # Eliminar instalación anterior después de aceptar
    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}Preparando actualización/reinstalación...${NC}"
        force_remove "$APP_DIR" "$GUIDE_TARGET"
    fi

    mkdir -p "$APP_DIR"
    ARCHIVE_NAME=$(basename "$DOWNLOAD_URL" | cut -d '?' -f1)
    ARCHIVE_PATH="$APP_DIR/$ARCHIVE_NAME"
    EXTRACT_DIR=$(mktemp -d)

    echo -e "${GREEN}Descargando $PKG_NAME...${NC}"
    wget -q --show-progress -O "$ARCHIVE_PATH" "$DOWNLOAD_URL" || { echo -e "${RED}Error descarga.${NC}"; return 1; }

    if [ -n "$SHA256" ]; then
        echo -e "${YELLOW}Verificando integridad del archivo...${NC}"
        echo "$SHA256  $ARCHIVE_PATH" | sha256sum -c - >/dev/null 2>&1 || {
            echo -e "${RED}Error: La suma SHA256 no coincide. El archivo podría estar corrupto.${NC}"
            rm -f "$ARCHIVE_PATH"
            return 1
        }
        echo -e "${GREEN}✓ SHA256 correcto.${NC}"
    fi

    extract_archive "$ARCHIVE_PATH" "$EXTRACT_DIR" || { rm -rf "$EXTRACT_DIR"; return 1; }

    (
        shopt -s dotglob nullglob
        files=("$SRC_DIR"/*)
        if ((${#files[@]})); then
            mv -- "${files[@]}" "$APP_DIR/"
        fi
    )
    rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
    EXTRACT_DIR=""

    create_symlinks "$APP_DIR" "$GUIDE_TARGET" "$PKG_NAME" "$AUTO_YES"
    maybe_run_guide "$PKG_NAME" "$APP_DIR" "$AUTO_YES" "$REPO_VERSION"

    echo -e "${GREEN}¡$PKG_NAME instalado correctamente! (versión $REPO_VERSION)${NC}"
    return 0
}

# ------------------------------------------------------------
# Instalación desde archivo .casata local
# ------------------------------------------------------------
install_from_file() {
    local ARCHIVE_FILE="$1"
    local AUTO_YES="$2"

    [ "$EUID" -ne 0 ] && { echo -e "${RED}Instalación global requiere root.${NC}"; return 1; }

    if [ ! -f "$ARCHIVE_FILE" ]; then
        echo -e "${RED}Error: Archivo no encontrado: $ARCHIVE_FILE${NC}"
        return 1
    fi

    if ! is_valid_package_file "$ARCHIVE_FILE"; then
        echo -e "${RED}Error: '$ARCHIVE_FILE' no es un paquete Casata válido (formatos: .casata, .zip, .tar.gz, .tgz, .tar.xz, .tar).${NC}"
        return 1
    fi

    local PKG_NAME
    PKG_NAME=$(normalize_pkg_name "$(basename "$ARCHIVE_FILE")")

    APPS_DIR="$GLOBAL_ROOT/apps"
    GUIDE_TARGET="GUIDE.json"
    mkdir -p "$APPS_DIR"
    APP_DIR="$APPS_DIR/$PKG_NAME"

    # Extraer el paquete .casata en un directorio temporal
    EXTRACT_DIR=$(mktemp -d)

    echo -e "${GREEN}Extrayendo $PKG_NAME desde archivo local...${NC}"
    if ! extract_archive "$ARCHIVE_FILE" "$EXTRACT_DIR"; then
        rm -rf "$EXTRACT_DIR"
        return 1
    fi

    # Variables para metadatos
    local REPO_VERSION=""
    local SHA256=""
    local -a APT_DEPS=() PACMAN_DEPS=() DNF_DEPS=() PIP_DEPS=() CASATA_DEPS=()
    local EXTERNAL_MODE=0
    local RELEASE_URL=""
    local GUIDE_ARRAY=""

    # Buscar DATA.json dentro del paquete extraído
    local DATA_FILE="$SRC_DIR/DATA.json"
    if [ -f "$DATA_FILE" ]; then
        echo -e "${YELLOW}Se encontró DATA.json, usando metadatos del paquete.${NC}"

        # Leer external_metadata
        local external_metadata
        external_metadata=$(jq -r '.external_metadata // false' "$DATA_FILE" 2>/dev/null || echo "false")
        if [[ "$external_metadata" == "true" ]]; then
            EXTERNAL_MODE=1
            echo -e "${YELLOW}Modo external_metadata activado. Se descargará el release oficial.${NC}"

            # Leer release.url
            RELEASE_URL=$(jq -r '.release.url // empty' "$DATA_FILE" 2>/dev/null || true)
            if [ -z "$RELEASE_URL" ]; then
                echo -e "${RED}Error: external_metadata es true pero no se encontró 'release.url'.${NC}"
                rm -rf "$EXTRACT_DIR"
                return 1
            fi

            # Leer guide (array)
            GUIDE_ARRAY=$(jq -c '.guide // []' "$DATA_FILE" 2>/dev/null || echo "[]")
            if [ "$GUIDE_ARRAY" == "[]" ]; then
                echo -e "${YELLOW}Aviso: No se encontró 'guide' en DATA.json. No se crearán enlaces.${NC}"
            fi
        fi

        # Leer campos comunes (version, dependencias, etc.) siempre
        REPO_VERSION=$(jq -r '.version // "0.0.0"' "$DATA_FILE" 2>/dev/null || true)
        if ! REPO_VERSION=$(resolve_version "$REPO_VERSION"); then
            REPO_VERSION="0.0.0"
            echo -e "${YELLOW}No se pudo resolver la versión del paquete; se asume 0.0.0.${NC}"
        fi
        SHA256=$(jq -r '.sha256 // empty' "$DATA_FILE" 2>/dev/null || true)
        split_to_array APT_DEPS "$(jq -r '.apt? // [] | .[]' "$DATA_FILE" 2>/dev/null || true)" || true
        split_to_array PACMAN_DEPS "$(jq -r '.pacman? // [] | .[]' "$DATA_FILE" 2>/dev/null || true)" || true
        split_to_array DNF_DEPS "$(jq -r '.dnf? // [] | .[]' "$DATA_FILE" 2>/dev/null || true)" || true
        split_to_array PIP_DEPS "$(jq -r '.pip? // [] | .[]' "$DATA_FILE" 2>/dev/null || true)" || true
        split_to_array CASATA_DEPS "$(jq -r '.casata? // [] | .[]' "$DATA_FILE" 2>/dev/null || true)" || true
    else
        # Si no hay DATA.json, intentar usar base de datos global o VERSION/DEPS.json (comportamiento anterior)
        local global_json="$DATA_DIR/${PKG_NAME}.json"
        if [ -f "$global_json" ]; then
            if jq empty "$global_json" 2>/dev/null; then
                echo -e "${YELLOW}No se encontró DATA.json. Usando metadatos de la base de datos global para '$PKG_NAME'.${NC}"
                REPO_VERSION=$(jq -r '.version // "0.0.0"' "$global_json" 2>/dev/null || true)
                if ! REPO_VERSION=$(resolve_version "$REPO_VERSION"); then
                    REPO_VERSION="0.0.0"
                    echo -e "${YELLOW}No se pudo resolver la versión global; se asume 0.0.0.${NC}"
                fi
                SHA256=$(jq -r '.sha256 // empty' "$global_json" 2>/dev/null || true)
                split_to_array APT_DEPS "$(jq -r '.apt? // [] | .[]' "$global_json" 2>/dev/null || true)" || true
                split_to_array PACMAN_DEPS "$(jq -r '.pacman? // [] | .[]' "$global_json" 2>/dev/null || true)" || true
                split_to_array DNF_DEPS "$(jq -r '.dnf? // [] | .[]' "$global_json" 2>/dev/null || true)" || true
                split_to_array PIP_DEPS "$(jq -r '.pip? // [] | .[]' "$global_json" 2>/dev/null || true)" || true
                split_to_array CASATA_DEPS "$(jq -r '.casata? // [] | .[]' "$global_json" 2>/dev/null || true)" || true
            else
                echo -e "${YELLOW}Advertencia: El archivo de base de datos global '$global_json' no es un JSON válido. Intentando con VERSION...${NC}"
                local version_file="$SRC_DIR/VERSION"
                if [ -f "$version_file" ]; then
                    REPO_VERSION=$(cat "$version_file" 2>/dev/null || true)
                    local deps_file="$SRC_DIR/DEPS.json"
                    if [ -f "$deps_file" ]; then
                        echo -e "${YELLOW}Se encontró DEPS.json, procesando dependencias...${NC}"
                        split_to_array APT_DEPS "$(jq -r '.apt? // [] | .[]' "$deps_file" 2>/dev/null || true)" || true
                        split_to_array PACMAN_DEPS "$(jq -r '.pacman? // [] | .[]' "$deps_file" 2>/dev/null || true)" || true
                        split_to_array DNF_DEPS "$(jq -r '.dnf? // [] | .[]' "$deps_file" 2>/dev/null || true)" || true
                        split_to_array PIP_DEPS "$(jq -r '.pip? // [] | .[]' "$deps_file" 2>/dev/null || true)" || true
                        split_to_array CASATA_DEPS "$(jq -r '.casata? // [] | .[]' "$deps_file" 2>/dev/null || true)" || true
                    fi
                else
                    echo -e "${RED}Error: El paquete no contiene DATA.json, VERSION, y la base de datos global es inválida.${NC}"
                    rm -rf "$EXTRACT_DIR"
                    return 1
                fi
            fi
        elif [ -f "$SRC_DIR/VERSION" ]; then
            echo -e "${YELLOW}No se encontró DATA.json ni base de datos global. Usando archivo VERSION y DEPS.json si existe.${NC}"
            REPO_VERSION=$(cat "$SRC_DIR/VERSION" 2>/dev/null || true)
            if [ -f "$SRC_DIR/DEPS.json" ]; then
                echo -e "${YELLOW}Se encontró DEPS.json, procesando dependencias...${NC}"
                split_to_array APT_DEPS "$(jq -r '.apt? // [] | .[]' "$SRC_DIR/DEPS.json" 2>/dev/null || true)" || true
                split_to_array PACMAN_DEPS "$(jq -r '.pacman? // [] | .[]' "$SRC_DIR/DEPS.json" 2>/dev/null || true)" || true
                split_to_array DNF_DEPS "$(jq -r '.dnf? // [] | .[]' "$SRC_DIR/DEPS.json" 2>/dev/null || true)" || true
                split_to_array PIP_DEPS "$(jq -r '.pip? // [] | .[]' "$SRC_DIR/DEPS.json" 2>/dev/null || true)" || true
                split_to_array CASATA_DEPS "$(jq -r '.casata? // [] | .[]' "$SRC_DIR/DEPS.json" 2>/dev/null || true)" || true
            fi
        else
            echo -e "${RED}Error: El paquete no contiene DATA.json, VERSION, y no se encontró en la base de datos global.${NC}"
            rm -rf "$EXTRACT_DIR"
            return 1
        fi
    fi

    # Version check antes de instalar dependencias
    if ! version_check "$APP_DIR" "$PKG_NAME" "$REPO_VERSION" "$AUTO_YES"; then
        rm -rf "$EXTRACT_DIR"
        return 2
    fi

    # Instalar dependencias (comunes para ambos modos)
    if [ "${SKIP_SYSTEM_DEPS:-0}" -eq 0 ]; then
        local -a SYSTEM_DEPS=()
        case "$PKG_MANAGER" in
            apt)    SYSTEM_DEPS=("${APT_DEPS[@]}") ;;
            pacman) SYSTEM_DEPS=("${PACMAN_DEPS[@]}") ;;
            dnf)    SYSTEM_DEPS=("${DNF_DEPS[@]}") ;;
        esac

        if [ ${#SYSTEM_DEPS[@]} -gt 0 ]; then
            echo -e "\n${YELLOW}Dependencias del sistema ($PKG_MANAGER) para $PKG_NAME:${NC}"
            printf '  • %s\n' "${SYSTEM_DEPS[@]}"
            if [ $AUTO_YES -eq 0 ]; then
                read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
                if [[ "$resp" =~ ^[Nn] ]]; then
                    echo -e "${YELLOW}Se omitió la instalación de dependencias del sistema.${NC}"
                else
                    install_system_deps SYSTEM_DEPS || { rm -rf "$EXTRACT_DIR"; return 1; }
                fi
            else
                install_system_deps SYSTEM_DEPS || { rm -rf "$EXTRACT_DIR"; return 1; }
            fi
        fi
    fi

    if [ "${SKIP_PIP_DEPS:-0}" -eq 0 ] && [ ${#PIP_DEPS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Dependencias Python para $PKG_NAME:${NC}"
        printf '  • %s\n' "${PIP_DEPS[@]}"
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Python con pip? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias pip.${NC}"
            else
                install_pip_deps PIP_DEPS || { rm -rf "$EXTRACT_DIR"; return 1; }
            fi
        else
            install_pip_deps PIP_DEPS || { rm -rf "$EXTRACT_DIR"; return 1; }
        fi
    fi

    if [ "${SKIP_CASATA_DEPS:-0}" -eq 0 ] && [ ${#CASATA_DEPS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Dependencias Casata para $PKG_NAME:${NC}"
        printf '  • %s\n' "${CASATA_DEPS[@]}"
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Casata? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias Casata.${NC}"
            else
                install_casata_deps CASATA_DEPS "$AUTO_YES" || { rm -rf "$EXTRACT_DIR"; return 1; }
            fi
        else
            install_casata_deps CASATA_DEPS "$AUTO_YES" || { rm -rf "$EXTRACT_DIR"; return 1; }
        fi
    fi

    # Eliminar instalación anterior
    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}Preparando actualización/reinstalación...${NC}"
        force_remove "$APP_DIR" "$GUIDE_TARGET"
    fi

    mkdir -p "$APP_DIR"

    # ----------------------------------------------
    # Modo external_metadata: descargar release oficial
    # ----------------------------------------------
    if [ $EXTERNAL_MODE -eq 1 ]; then
        echo -e "${GREEN}Descargando release oficial desde $RELEASE_URL...${NC}"
        local release_tmp=$(mktemp -d)
        local archive_name=$(basename "$RELEASE_URL" | cut -d '?' -f1)
        local archive_path="$release_tmp/$archive_name"

        if ! wget -q --show-progress -O "$archive_path" "$RELEASE_URL"; then
            echo -e "${RED}Error al descargar el release.${NC}"
            rm -rf "$release_tmp" "$EXTRACT_DIR"
            return 1
        fi

        echo -e "${YELLOW}Extrayendo release...${NC}"
        if ! extract_archive "$archive_path" "$release_tmp"; then
            echo -e "${RED}Error al extraer el release.${NC}"
            rm -rf "$release_tmp" "$EXTRACT_DIR"
            return 1
        fi

        # Mover contenido del release a APP_DIR
        (
            shopt -s dotglob nullglob
            files=("$SRC_DIR"/*)
            if ((${#files[@]})); then
                mv -- "${files[@]}" "$APP_DIR/"
            fi
        )
        rm -rf "$release_tmp"

        # Copiar archivos adicionales del paquete .casata (excepto DATA.json) a APP_DIR
        echo -e "${YELLOW}Copiando archivos adicionales del distribuidor...${NC}"
        (
            shopt -s dotglob nullglob
            # Cambiar al directorio EXTRACT_DIR (que contiene el contenido extraído del .casata)
            cd "$EXTRACT_DIR" || exit 1
            for item in *; do
                # Saltar DATA.json y cualquier otro archivo que no queramos copiar
                if [ "$item" != "DATA.json" ] && [ "$item" != "GUIDE.json" ] && [ "$item" != "DEPS.json" ] && [ "$item" != "VERSION" ]; then
                    if [ -e "$item" ]; then
                        # Copiar recursivamente, sobrescribiendo
                        cp -r -- "$item" "$APP_DIR/"
                    fi
                fi
            done
        )
    else
        # Modo normal: mover todo el contenido extraído del .casata a APP_DIR
        (
            shopt -s dotglob nullglob
            files=("$SRC_DIR"/*)
            if ((${#files[@]})); then
                mv -- "${files[@]}" "$APP_DIR/"
            fi
        )
    fi

    # Limpiar directorio de extracción del .casata
    rm -rf "$EXTRACT_DIR"
    EXTRACT_DIR=""

    # ------------------------------------------------------------
    # Crear enlaces simbólicos según GUIDE
    # ------------------------------------------------------------
    # Si estamos en modo external y tenemos GUIDE_ARRAY, generar GUIDE.json
    if [ $EXTERNAL_MODE -eq 1 ] && [ -n "$GUIDE_ARRAY" ] && [ "$GUIDE_ARRAY" != "[]" ]; then
        echo -e "${YELLOW}Generando GUIDE.json a partir del 'guide' del DATA.json...${NC}"
        if ! jq -n --argjson links "$GUIDE_ARRAY" '{links: $links}' > "$APP_DIR/GUIDE.json"; then
            echo -e "${RED}Error al generar GUIDE.json.${NC}"
            return 1
        fi
    fi

    # Crear enlaces (si existe GUIDE.json en APP_DIR)
    create_symlinks "$APP_DIR" "$GUIDE_TARGET" "$PKG_NAME" "$AUTO_YES"

    # Ejecutar GUIDE.sh si el paquete está en la lista de prioridad
    maybe_run_guide "$PKG_NAME" "$APP_DIR" "$AUTO_YES" "$REPO_VERSION"

    echo -e "${GREEN}¡$PKG_NAME instalado correctamente! (versión $REPO_VERSION)${NC}"
    return 0
}

# ============================================================
# INICIO DEL SCRIPT
# ============================================================
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}"
    echo "En Debian/Ubuntu: sudo apt install jq wget"
    echo "En Arch Linux:    sudo pacman -S jq wget"
    echo "En Fedora:        sudo dnf install jq wget"

    exit 1
fi

# Variables globales
AUTO_YES=0
FILE_MODE=0
PACKAGES=()
ORIGINAL_ARGS=("$@")

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y) AUTO_YES=1 ;;
        -f|--file) FILE_MODE=1 ;;
        -*)
            echo -e "${RED}Opción desconocida: $1${NC}"
            exit 1
            ;;
        *) PACKAGES+=("$1") ;;
    esac
    shift
done

if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo -e "${RED}Error: Falta el nombre del paquete o archivo .casata.${NC}"
    exit 1
fi

# Auto-detectar archivos locales
if [ $FILE_MODE -eq 0 ]; then
    all_files=1
    for pkg in "${PACKAGES[@]}"; do
        if ! is_valid_package_file "$pkg"; then
            all_files=0
            break
        fi
    done
    if [ $all_files -eq 1 ]; then
        FILE_MODE=1
        echo -e "${YELLOW}Detectados archivos locales, activando modo archivo.${NC}"
    fi
fi

# Redirigir actualización de Casata
if [ $FILE_MODE -eq 0 ] && [ ${#PACKAGES[@]} -eq 1 ] && [ "${PACKAGES[0]}" == "casata" ]; then
    echo -e "${GREEN}Redirigiendo a la actualización de Casata...${NC}"
    exec "$GLOBAL_ROOT/modules/install-casata.sh" "${ORIGINAL_ARGS[@]}"
    echo -e "${RED}Error: No se pudo ejecutar el módulo de actualización de Casata.${NC}"
    exit 1
fi

# Cargar rutas protegidas
load_protected_paths

init_package_manager

# ----------------------------
# Modo archivo local (.casata)
# ----------------------------
if [ $FILE_MODE -eq 1 ]; then
    FAILED=()
    for FILE in "${PACKAGES[@]}"; do
        echo -e "\n${GREEN}========================================${NC}"
        echo -e "${GREEN}Instalando desde archivo: $FILE${NC}"
        echo -e "${GREEN}========================================${NC}"
        set +e
        install_from_file "$FILE" "$AUTO_YES"
        ret=$?
        set -e
        case $ret in
            0) echo -e "${GREEN}✔ $FILE instalado correctamente.${NC}" ;;
            2) echo -e "${YELLOW}⊘ $FILE omitido (instalación cancelada).${NC}" ;;
            *) echo -e "${RED}✖ Falló la instalación de $FILE.${NC}"; FAILED+=("$FILE") ;;
        esac
    done

    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    if [ ${#FAILED[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ Todos los archivos se procesaron correctamente.${NC}"
    else
        echo -e "${RED}✖ Los siguientes archivos fallaron: ${FAILED[*]}${NC}"
    fi
    echo -e "${GREEN}════════════════════════════════════════${NC}"

    if [ ${#FAILED[@]} -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

# ----------------------------
# Modo repositorio (múltiples paquetes)
# ----------------------------
if [ ${#PACKAGES[@]} -gt 1 ]; then
    echo -e "\n${YELLOW}Resolviendo dependencias de todos los paquetes solicitados...${NC}"

    for PKG in "${PACKAGES[@]}"; do
        collect_package_deps "$PKG" || exit 1
    done

    ALL_SYSTEM_DEPS=()
    case "$PKG_MANAGER" in
        apt)    ALL_SYSTEM_DEPS=("${!COLLECTED_APT[@]}") ;;
        pacman) ALL_SYSTEM_DEPS=("${!COLLECTED_PACMAN[@]}") ;;
        dnf)    ALL_SYSTEM_DEPS=("${!COLLECTED_DNF[@]}") ;;
    esac

    if [ ${#ALL_SYSTEM_DEPS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Dependencias del sistema ($PKG_MANAGER) para todos los paquetes:${NC}"
        printf '  • %s\n' "${ALL_SYSTEM_DEPS[@]}"
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias del sistema.${NC}"
            else
                install_system_deps ALL_SYSTEM_DEPS || exit 1
            fi
        else
            install_system_deps ALL_SYSTEM_DEPS || exit 1
        fi
    fi

    ALL_PIP_DEPS=()
    if [ ${#COLLECTED_PIP[@]} -gt 0 ]; then
        ALL_PIP_DEPS=("${!COLLECTED_PIP[@]}")
    fi

    if [ ${#ALL_PIP_DEPS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Dependencias Python para todos los paquetes:${NC}"
        printf '  • %s\n' "${ALL_PIP_DEPS[@]}"
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Python con pip? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias pip.${NC}"
            else
                install_pip_deps ALL_PIP_DEPS || exit 1
            fi
        else
            install_pip_deps ALL_PIP_DEPS || exit 1
        fi
    fi

    declare -a INSTALL_ORDER=()
    declare -A ADDED_PKGS=()

    for dep in "${CASATA_ORDER[@]}"; do
        if [ -z "${ADDED_PKGS[$dep]:-}" ]; then
            INSTALL_ORDER+=("$dep")
            ADDED_PKGS[$dep]=1
        fi
    done

    for pkg in "${PACKAGES[@]}"; do
        if [ -z "${ADDED_PKGS[$pkg]:-}" ]; then
            INSTALL_ORDER+=("$pkg")
            ADDED_PKGS[$pkg]=1
        fi
    done

    SKIP_SYSTEM_DEPS=1
    SKIP_PIP_DEPS=1
    SKIP_CASATA_DEPS=1
    export SKIP_SYSTEM_DEPS SKIP_PIP_DEPS SKIP_CASATA_DEPS

    FAILED=()
    for PKG in "${INSTALL_ORDER[@]}"; do
        echo -e "\n${GREEN}========================================${NC}"
        echo -e "${GREEN}Instalando: $PKG${NC}"
        echo -e "${GREEN}========================================${NC}"
        set +e
        install_one "$PKG" "$AUTO_YES"
        ret=$?
        set -e
        case $ret in
            0) echo -e "${GREEN}✔ $PKG instalado correctamente.${NC}" ;;
            2) echo -e "${YELLOW}⊘ $PKG omitido (instalación cancelada).${NC}" ;;
            *) echo -e "${RED}✖ Falló la instalación de $PKG.${NC}"; FAILED+=("$PKG") ;;
        esac
    done

    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    if [ ${#FAILED[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ Todos los paquetes se procesaron correctamente.${NC}"
    else
        echo -e "${RED}✖ Los siguientes paquetes fallaron: ${FAILED[*]}${NC}"
    fi
    echo -e "${GREEN}════════════════════════════════════════${NC}"

    if [ ${#FAILED[@]} -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

# ----------------------------
# Modo paquete único
# ----------------------------
FAILED=()
for PKG in "${PACKAGES[@]}"; do
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Instalando: $PKG${NC}"
    echo -e "${GREEN}========================================${NC}"
    set +e
    install_one "$PKG" "$AUTO_YES"
    ret=$?
    set -e
    case $ret in
        0) echo -e "${GREEN}✔ $PKG instalado correctamente.${NC}" ;;
        2) echo -e "${YELLOW}⊘ $PKG omitido (instalación cancelada).${NC}" ;;
        *) echo -e "${RED}✖ Falló la instalación de $PKG.${NC}"; FAILED+=("$PKG") ;;
    esac
done

echo -e "\n${GREEN}════════════════════════════════════════${NC}"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ Todos los paquetes se procesaron correctamente.${NC}"
else
    echo -e "${RED}✖ Los siguientes paquetes fallaron: ${FAILED[*]}${NC}"
fi
echo -e "${GREEN}════════════════════════════════════════${NC}"

if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
fi
exit 0
