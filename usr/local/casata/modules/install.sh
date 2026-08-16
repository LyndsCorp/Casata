#!/bin/bash

# /usr/local/casata/modules/install.sh
# Copyright (C) 2026 David Baña Szymaniak
# GPL v3 License
# Script de instalar aplicaciones en Casata 1.3.5

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

# Arrays asociativos para recopilar dependencias de todos los paquetes
declare -A COLLECTED_APT=()
declare -A COLLECTED_PACMAN=()
declare -A COLLECTED_DNF=()
declare -A COLLECTED_PIP=()
declare -A COLLECTED_CASATA=()
declare -A VISITED_PACKAGES=()
declare -a CASATA_ORDER=()   # Orden topológico de dependencias Casata

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ------------------------------------------------------------
# Estado del gestor de paquetes
# ------------------------------------------------------------
PKG_MANAGER=""            # apt, pacman o dnf
PM_UPDATE_DONE=0          # 0=no hecho, 1=hecho OK, 2=falló

# ------------------------------------------------------------
# Directorios protegidos donde NUNCA se puede crear un enlace
# ------------------------------------------------------------
PROTECTED_DIRS=(
    "/usr/local/casata"
    "/home"
    "/boot"
    "/root"
    "/dev"
    "/sys"
)

PROTECTED_FILES=(
    # --- Instaladores ---
    "/usr/bin/casata"
    "/usr/bin/apt"
    "/usr/bin/pacman"
    "/usr/bin/dnf"
    "/usr/bin/wget"
    "/usr/bin/curl"

    # --- Dependencias de Casata ---
    "/usr/bin/jq"
    "/usr/bin/tar"
    "/usr/bin/unzip"
    "/usr/bin/zip"

    # --- GNU coreutils ---
    "/usr/bin/basename"
    "/usr/bin/cat"
    "/usr/bin/chgrp"
    "/usr/bin/chmod"
    "/usr/bin/chown"
    "/usr/bin/cksum"
    "/usr/bin/comm"
    "/usr/bin/cp"
    "/usr/bin/csplit"
    "/usr/bin/cut"
    "/usr/bin/date"
    "/usr/bin/dd"
    "/usr/bin/df"
    "/usr/bin/dir"
    "/usr/bin/dircolors"
    "/usr/bin/dirname"
    "/usr/bin/du"
    "/usr/bin/echo"
    "/usr/bin/env"
    "/usr/bin/expand"
    "/usr/bin/expr"
    "/usr/bin/factor"
    "/usr/bin/false"
    "/usr/bin/fmt"
    "/usr/bin/fold"
    "/usr/bin/groups"
    "/usr/bin/head"
    "/usr/bin/hostid"
    "/usr/bin/id"
    "/usr/bin/install"
    "/usr/bin/join"
    "/usr/bin/kill"
    "/usr/bin/link"
    "/usr/bin/ln"
    "/usr/bin/logname"
    "/usr/bin/ls"
    "/usr/bin/md5sum"
    "/usr/bin/mkdir"
    "/usr/bin/mkfifo"
    "/usr/bin/mknod"
    "/usr/bin/mktemp"
    "/usr/bin/mv"
    "/usr/bin/nice"
    "/usr/bin/nl"
    "/usr/bin/nohup"
    "/usr/bin/nproc"
    "/usr/bin/numfmt"
    "/usr/bin/od"
    "/usr/bin/paste"
    "/usr/bin/pathchk"
    "/usr/bin/pinky"
    "/usr/bin/pr"
    "/usr/bin/printenv"
    "/usr/bin/printf"
    "/usr/bin/ptx"
    "/usr/bin/pwd"
    "/usr/bin/readlink"
    "/usr/bin/realpath"
    "/usr/bin/rm"
    "/usr/bin/rmdir"
    "/usr/bin/runcon"
    "/usr/bin/seq"
    "/usr/bin/sha1sum"
    "/usr/bin/sha224sum"
    "/usr/bin/sha256sum"
    "/usr/bin/sha384sum"
    "/usr/bin/sha512sum"
    "/usr/bin/shred"
    "/usr/bin/shuf"
    "/usr/bin/sleep"
    "/usr/bin/sort"
    "/usr/bin/split"
    "/usr/bin/stat"
    "/usr/bin/stdbuf"
    "/usr/bin/stty"
    "/usr/bin/sum"
    "/usr/bin/tac"
    "/usr/bin/tail"
    "/usr/bin/tee"
    "/usr/bin/test"
    "/usr/bin/timeout"
    "/usr/bin/touch"
    "/usr/bin/tr"
    "/usr/bin/true"
    "/usr/bin/tsort"
    "/usr/bin/tty"
    "/usr/bin/uname"
    "/usr/bin/unexpand"
    "/usr/bin/uniq"
    "/usr/bin/unlink"
    "/usr/bin/users"
    "/usr/bin/vdir"
    "/usr/bin/wc"
    "/usr/bin/who"
    "/usr/bin/whoami"
    "/usr/bin/yes"
    "/usr/bin/["

    # --- util-linux ---
    "/usr/bin/addpart"
    "/usr/bin/agetty"
    "/usr/bin/blkdiscard"
    "/usr/bin/blkid"
    "/usr/bin/blockdev"
    "/usr/bin/cal"
    "/usr/bin/chcpu"
    "/usr/bin/chmem"
    "/usr/bin/choom"
    "/usr/bin/chrt"
    "/usr/bin/col"
    "/usr/bin/colcrt"
    "/usr/bin/colrm"
    "/usr/bin/column"
    "/usr/bin/ctrlaltdel"
    "/usr/bin/dmesg"
    "/usr/bin/eject"
    "/usr/bin/fallocate"
    "/usr/bin/fincore"
    "/usr/bin/findmnt"
    "/usr/bin/flock"
    "/usr/bin/getopt"
    "/usr/bin/hexdump"
    "/usr/bin/hwclock"
    "/usr/bin/ionice"
    "/usr/bin/ipcmk"
    "/usr/bin/ipcrm"
    "/usr/bin/ipcs"
    "/usr/bin/isosize"
    "/usr/bin/killall"
    "/usr/bin/last"
    "/usr/bin/lastb"
    "/usr/bin/ldattach"
    "/usr/bin/logger"
    "/usr/bin/login"
    "/usr/bin/look"
    "/usr/bin/lsblk"
    "/usr/bin/lscpu"
    "/usr/bin/lsipc"
    "/usr/bin/lslocks"
    "/usr/bin/lslogins"
    "/usr/bin/lsns"
    "/usr/bin/mcookie"
    "/usr/bin/mesg"
    "/usr/bin/mkfs"
    "/usr/bin/mkswap"
    "/usr/bin/mount"
    "/usr/bin/mountpoint"
    "/usr/bin/namei"
    "/usr/bin/nsenter"
    "/usr/bin/pivot_root"
    "/usr/bin/partx"
    "/usr/bin/prlimit"
    "/usr/bin/raw"
    "/usr/bin/readprofile"
    "/usr/bin/rename"
    "/usr/bin/renice"
    "/usr/bin/rev"
    "/usr/bin/rfkill"
    "/usr/bin/runuser"
    "/usr/bin/script"
    "/usr/bin/scriptreplay"
    "/usr/bin/setarch"
    "/usr/bin/setpriv"
    "/usr/bin/setterm"
    "/usr/bin/su"
    "/usr/bin/swaplabel"
    "/usr/bin/swapoff"
    "/usr/bin/swapon"
    "/usr/bin/taskset"
    "/usr/bin/ul"
    "/usr/bin/unshare"
    "/usr/bin/utmpdump"
    "/usr/bin/uclampset"
    "/usr/bin/wall"
    "/usr/bin/wdctl"
    "/usr/bin/whereis"
    "/usr/bin/wipefs"
    "/usr/bin/write"
    "/usr/bin/zramctl"

    # --- Binarios en /usr/local/bin (evitar secuestro) ---
    "/usr/local/bin/casata"
    "/usr/local/bin/sudo"
    "/usr/local/bin/bash"
    "/usr/local/bin/python3"
    "/usr/local/bin/python"
    "/usr/local/bin/perl"
)

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
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v dnf &>/dev/null; then
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
# Instalación de dependencias del sistema (adaptada a cada gestor)
# ------------------------------------------------------------
install_system_deps() {
    local deps="$1"
    [ -z "$deps" ] && return 0

    echo -e "${YELLOW}Intentando instalar dependencias del sistema ($PKG_MANAGER): $deps${NC}"

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
                    apt install -y $deps
                else
                    apt install $deps
                fi
                ;;
            pacman)
                # Intento inicial sin sincronizar bases
                if [ "${AUTO_YES:-0}" -eq 1 ]; then
                    pacman -S --needed --noconfirm $deps && return 0
                else
                    pacman -S --needed $deps && return 0
                fi

                # Fallo: pedir sincronización de bases
                echo -e "${YELLOW}No se encontraron los paquetes. Puede ser necesario sincronizar las bases de datos.${NC}"
                if [ "${AUTO_YES:-0}" -eq 1 ]; then
                    echo -e "${YELLOW}(AUTO_YES) Sincronizando bases con pacman -Sy... (¡cuidado con actualizaciones parciales!)${NC}"
                    if pacman -Sy --noconfirm; then
                        PM_UPDATE_DONE=1
                        pacman -S --needed --noconfirm $deps
                    else
                        PM_UPDATE_DONE=2
                        echo -e "${RED}ERROR: pacman -Sy falló.${NC}"
                        return 1
                    fi
                else
                    echo -e "${YELLOW}Se recomienda ejecutar 'pacman -Sy' manualmente y luego reintentar.${NC}"
                    read -p "¿Sincronizar bases ahora y continuar? (puede causar actualizaciones parciales) [s/N]: " resp < /dev/tty
                    if [[ "$resp" =~ ^[sSyY] ]]; then
                        if pacman -Sy --noconfirm; then
                            PM_UPDATE_DONE=1
                            pacman -S --needed $deps
                        else
                            PM_UPDATE_DONE=2
                            echo -e "${RED}ERROR: pacman -Sy falló.${NC}"
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
                    dnf install -y $deps
                else
                    dnf install $deps
                fi
                ;;
            *)
                echo -e "${RED}Gestor de paquetes no soportado: $PKG_MANAGER${NC}"
                return 1
                ;;
        esac
    }

    if _try_install; then
        return 0
    fi

    # Fallback si el binario del gestor no existe
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
        return 0
    else
        echo -e "${RED}Error al instalar dependencias con $PKG_MANAGER.${NC}"
        return 1
    fi
}

# ------------------------------------------------------------
# Instalación de dependencias pip
# ------------------------------------------------------------
install_pip_deps() {
    local pkgs="$1"
    local venv_path="/usr/local/casata/python-venv"
    local lock_file="$venv_path/.install.lock"

    [ -z "$pkgs" ] && return 0

    if ! ls "$venv_path/bin/python" >/dev/null 2>&1; then
        echo -e "${YELLOW}Creando entorno virtual compartido en $venv_path...${NC}"
        if command -v python3 &>/dev/null; then
            python3 -m venv "$venv_path" || { echo -e "${RED}Error al crear venv.${NC}"; return 1; }
        else
            echo -e "${RED}Error: python3 no encontrado.${NC}"
            return 1
        fi
    fi

    touch "$lock_file" 2>/dev/null || { echo -e "${RED}Error: No se puede crear lock file.${NC}"; return 1; }

    local pip_pkgs=()
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && pip_pkgs+=("$pkg")
    done <<< "$pkgs"

    [ ${#pip_pkgs[@]} -eq 0 ] && return 0

    echo -e "${YELLOW}Instalando dependencias Python: ${pip_pkgs[*]}${NC}"
    flock --exclusive "$lock_file" "$venv_path/bin/pip" install "${pip_pkgs[@]}" || {
        echo -e "${RED}Error al instalar dependencias pip.${NC}"
        return 1
    }
    return 0
}

# ------------------------------------------------------------
# Instalación de dependencias Casata (con caché de dependencias)
# ------------------------------------------------------------
install_casata_deps() {
    local casata_pkgs="$1"
    local auto_yes="${2:-0}"            # heredado de install_one

    [ -z "$casata_pkgs" ] && return 0

    # Inicializar caché si no existe
    if [ ! -f "$CASATA_DEP_CACHE" ]; then
        touch "$CASATA_DEP_CACHE"
    fi

    echo -e "${YELLOW}Instalando dependencias Casata: $casata_pkgs${NC}"

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        # Si ya fue procesado en esta resolución, salta
        if grep -qxF "$pkg" "$CASATA_DEP_CACHE"; then
            echo -e "${YELLOW}→ Dependencia Casata '$pkg' ya fue procesada, omitiendo.${NC}"
            continue
        fi

        echo "$pkg" >> "$CASATA_DEP_CACHE"

        echo -e "${YELLOW}→ Instalando dependencia Casata: $pkg${NC}"

        if [ "$auto_yes" -eq 1 ]; then
            "$GLOBAL_ROOT/modules/install.sh" -y "$pkg"
        else
            "$GLOBAL_ROOT/modules/install.sh" "$pkg"
        fi || {
            echo -e "${RED}Error al instalar la dependencia Casata '$pkg'.${NC}"
            return 1
        }
    done <<< "$casata_pkgs"

    return 0
}

# ------------------------------------------------------------
# Recopilación recursiva de dependencias para instalación por lotes
# ------------------------------------------------------------
collect_package_deps() {
    local pkg="$1"

    # Evitar bucles infinitos
    if [ "${VISITED_PACKAGES[$pkg]:-0}" -eq 1 ]; then
        return 0
    fi
    VISITED_PACKAGES[$pkg]=1

    local pkg_file="$DATA_DIR/${pkg}.json"
    [ -f "$pkg_file" ] || return 0

    local dep

    # Dependencias del sistema
    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_APT["$dep"]=1
    done < <(jq -r '.apt? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_PACMAN["$dep"]=1
    done < <(jq -r '.pacman? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_DNF["$dep"]=1
    done < <(jq -r '.dnf? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    # Dependencias Python
    while IFS= read -r dep; do
        [ -n "$dep" ] && COLLECTED_PIP["$dep"]=1
    done < <(jq -r '.pip? // [] | .[]' "$pkg_file" 2>/dev/null || true)

    # Dependencias Casata (recursivas, en orden topológico)
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue

        if [ "${VISITED_PACKAGES[$dep]:-0}" -eq 0 ]; then
            COLLECTED_CASATA["$dep"]=1
            collect_package_deps "$dep"
            CASATA_ORDER+=("$dep")        # se añade después de sus propias dependencias
        else
            COLLECTED_CASATA["$dep"]=1    # ya fue visitado, pero asegurarse de que esté marcado
        fi
    done < <(jq -r '.casata? // [] | .[]' "$pkg_file" 2>/dev/null || true)
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

# ------------------------------------------------------------
# Función principal de instalación
# ------------------------------------------------------------
install_one() {
    local PKG_NAME="$1"
    local AUTO_YES="$2"
    local DOWNLOAD_ONLY="$3"

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

    # Leer dependencias con tolerancia a string único
    APT_DEPS=$(jq -r '.apt? // [] | .[]' "$PKG_FILE")
    PACMAN_DEPS=$(jq -r '.pacman? // [] | .[]' "$PKG_FILE")
    DNF_DEPS=$(jq -r '.dnf? // [] | .[]' "$PKG_FILE")
    PIP_DEPS=$(jq -r '.pip? // [] | .[]' "$PKG_FILE")
    CASATA_DEPS=$(jq -r '.casata? // [] | .[]' "$PKG_FILE")

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
                echo -e "${YELLOW}La versión instalada ($INSTALLED_VERSION) es más reciente que la del repositorio ($REPO_VERSION).${NC}"
                if [ $AUTO_YES -eq 0 ]; then
                    read -p "¿Quieres actualizar (downgrade) a la versión del repositorio? [s/N] " resp < /dev/tty
                    if [[ "$resp" =~ ^[sSyY] ]]; then
                        NEED_UPDATE=2
                    else
                        echo -e "${YELLOW}No se hará nada.${NC}"
                        return 0
                    fi
                else
                    echo -e "${YELLOW}Usando -y: se actualizará (downgrade) automáticamente.${NC}"
                    NEED_UPDATE=2
                fi
            fi
        else
            echo -e "${YELLOW}Paquete instalado pero sin archivo VERSION. Se reinstalará.${NC}"
            NEED_UPDATE=2
        fi
    fi

    # ---------------------------
    # Dependencias del sistema
    # ---------------------------
    if [ "${SKIP_SYSTEM_DEPS:-0}" -eq 0 ]; then
        local SYSTEM_DEPS=""
        case "$PKG_MANAGER" in
            apt)    SYSTEM_DEPS="$APT_DEPS" ;;
            pacman) SYSTEM_DEPS="$PACMAN_DEPS" ;;
            dnf)    SYSTEM_DEPS="$DNF_DEPS" ;;
        esac

        if [ -n "$SYSTEM_DEPS" ]; then
            echo -e "\n${YELLOW}Dependencias del sistema ($PKG_MANAGER) para $PKG_NAME:${NC}"
            echo "$SYSTEM_DEPS" | sed 's/^/  • /'
            if [ $AUTO_YES -eq 0 ]; then
                read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
                if [[ "$resp" =~ ^[Nn] ]]; then
                    echo -e "${YELLOW}Se omitió la instalación de dependencias del sistema.${NC}"
                else
                    install_system_deps "$(echo "$SYSTEM_DEPS" | tr '\n' ' ')" || return 1
                fi
            else
                install_system_deps "$(echo "$SYSTEM_DEPS" | tr '\n' ' ')" || return 1
            fi
        fi
    fi

    # ---------------------------
    # Dependencias pip
    # ---------------------------
    if [ "${SKIP_PIP_DEPS:-0}" -eq 0 ]; then
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
    fi

    # ---------------------------
    # Dependencias Casata
    # ---------------------------
    if [ "${SKIP_CASATA_DEPS:-0}" -eq 0 ]; then
        if [ -n "$CASATA_DEPS" ]; then
            echo -e "\n${YELLOW}Dependencias Casata para $PKG_NAME:${NC}"
            echo "$CASATA_DEPS" | sed 's/^/  • /'
            if [ $AUTO_YES -eq 0 ]; then
                read -p "¿Instalar dependencias Casata? [S/n] " resp < /dev/tty
                if [[ "$resp" =~ ^[Nn] ]]; then
                    echo -e "${YELLOW}Se omitió la instalación de dependencias Casata.${NC}"
                else
                    install_casata_deps "$CASATA_DEPS" "$AUTO_YES" || return 1
                fi
            else
                install_casata_deps "$CASATA_DEPS" "$AUTO_YES" || return 1
            fi
        fi
    fi

    if [ $NEED_UPDATE -eq 1 ] || [ $NEED_UPDATE -eq 2 ]; then
        echo -e "${YELLOW}Preparando actualización/reinstalación...${NC}"
        force_remove "$APP_DIR" "$GUIDE_TARGET"
    fi

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

    # ------------------------------------------------
    # Crear enlaces simbólicos CON PROTECCIONES ACTIVAS
    # ------------------------------------------------
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

            real_target=$(canonical_path "$TARGET_LINK")
            link_dir=$(dirname "$TARGET_LINK")
            real_dir=$(canonical_path "$link_dir")

            # --- VERIFICACIÓN DE DIRECTORIOS PROTEGIDOS ---
            skip=false
            for protected in "${PROTECTED_DIRS[@]}"; do
                real_protected=$(canonical_path "$protected")
                if [ "$real_dir" = "$real_protected" ] || [[ "$real_dir" == "$real_protected/"* ]]; then
                    echo -e "${RED}🚫  Error de seguridad: No se permite crear enlaces en '$link_dir' (directorio protegido). Enlace '$LINK_NAME' omitido.${NC}"
                    skip=true
                    break
                fi
            done
            $skip && continue

            # --- VERIFICACIÓN DE ARCHIVOS PROTEGIDOS ---
            for protected in "${PROTECTED_FILES[@]}"; do
                real_protected=$(canonical_path "$protected")
                if [ "$real_target" = "$real_protected" ]; then
                    echo -e "${RED}🚫  Error de seguridad: No se permite sobrescribir el archivo protegido '$protected'. Enlace '$LINK_NAME' omitido.${NC}"
                    skip=true
                    break
                fi
            done
            $skip && continue

            # --- Gestión de sobrescritura normal ---
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

    # ------------------------------------------------------------
    # Ejecución de GUIDE.sh para paquetes autorizados
    # ------------------------------------------------------------
    if [ -f "$SINGREPOS_PRIORITY" ]; then
        if grep -qxF "$PKG_NAME" "$SINGREPOS_PRIORITY" 2>/dev/null; then
            echo -e "\n${YELLOW}Este paquete puede modificar archivos del sistema.${NC}"
            echo -e "\nRepositorio autorizado:"
            echo -e "  ${GREEN}$PKG_NAME${NC}"
            echo ""
            if [ $AUTO_YES -eq 1 ]; then
                echo -e "${YELLOW}Usando -y: se ejecutará GUIDE.sh automáticamente.${NC}"
            else
                read -p "¿Continuar? (S/n): " resp < /dev/tty
                if [[ ! "$resp" =~ ^[SsYy]?$ ]]; then
                    echo -e "${YELLOW}Modificaciones del sistema omitidas. Puede ejecutar manualmente GUIDE.sh desde $APP_DIR.${NC}"
                    echo -e "${GREEN}¡$PKG_NAME instalado correctamente! (versión $REPO_VERSION)${NC}"
                    return 0
                fi
            fi

            GUIDE_SCRIPT="$APP_DIR/GUIDE.sh"
            if [ -f "$GUIDE_SCRIPT" ]; then
                echo -e "${YELLOW}Ejecutando GUIDE.sh...${NC}"
                if bash "$GUIDE_SCRIPT"; then
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
    fi

    echo -e "${GREEN}¡$PKG_NAME instalado correctamente! (versión $REPO_VERSION)${NC}"
    return 0
}

# ============================================================
# INICIO DEL SCRIPT
# ============================================================
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    echo -e "${RED}Error: Se requieren 'jq' y 'wget'.${NC}"
    exit 1
fi

# Variables globales antes de cualquier inicialización
AUTO_YES=0
DOWNLOAD_ONLY=0
PACKAGES=()

init_package_manager

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

if [ ${#PACKAGES[@]} -eq 1 ] && [ "${PACKAGES[0]}" == "casata" ]; then
    echo -e "${GREEN}Redirigiendo a la actualización de Casata...${NC}"
    exec "$GLOBAL_ROOT/modules/install-casata.sh" "$@"
    echo -e "${RED}Error: No se pudo ejecutar el módulo de actualización de Casata.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# MODO MULTI-PAQUETE: resolver dependencias primero
# ------------------------------------------------------------
if [ ${#PACKAGES[@]} -gt 1 ]; then
    echo -e "\n${YELLOW}Resolviendo dependencias de todos los paquetes solicitados...${NC}"

    for PKG in "${PACKAGES[@]}"; do
        collect_package_deps "$PKG"
    done

    # ---------- Dependencias del sistema (una sola vez) ----------
    ALL_SYSTEM_DEPS=""
    case "$PKG_MANAGER" in
        apt)    ALL_SYSTEM_DEPS="${!COLLECTED_APT[*]}" ;;
        pacman) ALL_SYSTEM_DEPS="${!COLLECTED_PACMAN[*]}" ;;
        dnf)    ALL_SYSTEM_DEPS="${!COLLECTED_DNF[*]}" ;;
    esac

    if [ -n "$ALL_SYSTEM_DEPS" ]; then
        echo -e "\n${YELLOW}Dependencias del sistema ($PKG_MANAGER) para todos los paquetes:${NC}"
        echo "$ALL_SYSTEM_DEPS" | tr ' ' '\n' | sed 's/^/  • /'
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias del sistema? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias del sistema.${NC}"
            else
                install_system_deps "$ALL_SYSTEM_DEPS" || exit 1
            fi
        else
            install_system_deps "$ALL_SYSTEM_DEPS" || exit 1
        fi
    fi

    # ---------- Dependencias Python (una sola vez) ----------
    ALL_PIP_DEPS=""
    if [ ${#COLLECTED_PIP[@]} -gt 0 ]; then
        ALL_PIP_DEPS=$(printf '%s\n' "${!COLLECTED_PIP[@]}")
    fi

    if [ -n "$ALL_PIP_DEPS" ]; then
        echo -e "\n${YELLOW}Dependencias Python para todos los paquetes:${NC}"
        echo "$ALL_PIP_DEPS" | sed 's/^/  • /'
        if [ $AUTO_YES -eq 0 ]; then
            read -p "¿Instalar dependencias Python con pip? [S/n] " resp < /dev/tty
            if [[ "$resp" =~ ^[Nn] ]]; then
                echo -e "${YELLOW}Se omitió la instalación de dependencias pip.${NC}"
            else
                install_pip_deps "$ALL_PIP_DEPS" || exit 1
            fi
        else
            install_pip_deps "$ALL_PIP_DEPS" || exit 1
        fi
    fi

    # ---------- Construir orden final de instalación ----------
    declare -a INSTALL_ORDER=()
    declare -A ADDED_PKGS=()

    # Primero las dependencias Casata en orden topológico
    for dep in "${CASATA_ORDER[@]}"; do
        if [ -z "${ADDED_PKGS[$dep]:-}" ]; then
            INSTALL_ORDER+=("$dep")
            ADDED_PKGS[$dep]=1
        fi
    done

    # Después los paquetes pedidos por el usuario
    for pkg in "${PACKAGES[@]}"; do
        if [ -z "${ADDED_PKGS[$pkg]:-}" ]; then
            INSTALL_ORDER+=("$pkg")
            ADDED_PKGS[$pkg]=1
        fi
    done

    # ---------- Instalar sin volver a procesar dependencias ----------
    SKIP_SYSTEM_DEPS=1
    SKIP_PIP_DEPS=1
    SKIP_CASATA_DEPS=1
    export SKIP_SYSTEM_DEPS SKIP_PIP_DEPS SKIP_CASATA_DEPS

    FAILED=()
    for PKG in "${INSTALL_ORDER[@]}"; do
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
fi

# ============================================================
# MODO PAQUETE ÚNICO (comportamiento original)
# ============================================================
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
