#!/bin/bash
# /usr/local/casata/modules/history.sh
# Copyright (C) 2026 David Baña Szymaniak

CASATA_ROOT="/usr/local/casata"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Cargar librería si existe
if [ -f "$CASATA_ROOT/lib/history-lib.sh" ]; then
    source "$CASATA_ROOT/lib/history-lib.sh"
fi

show_help() {
    cat <<EOF
Uso: casata history [OPCIONES]

Opciones:
  --user [nombre]   Ver historial de un usuario específico.
                    Sin nombre, usa el usuario actual.
                    (Por defecto se muestra el historial global/root)
  --type <tipo>     Filtrar por tipo (COMMAND, COMMAND_RESULT, DEPENDENCIES_*, SYMLINK_*, DOWNLOAD, etc.)
  --search <texto>  Buscar texto en las líneas
  --lines N         Mostrar solo las últimas N líneas
  --disable         Desactivar el registro de historial
  --enable          Reactivar el registro de historial
  --clear           Limpiar el historial (pide confirmación)
  --help            Mostrar esta ayuda

Sin opciones, muestra el historial global (de root) para todos los usuarios.
EOF
}

# Pager tipo git log (sale con q o Ctrl+C)
show_with_pager() {
    if [ -t 1 ]; then
        if command -v less &>/dev/null; then
            less -R
        elif command -v more &>/dev/null; then
            more
        else
            cat
        fi
    else
        cat
    fi
}

USER_SPEC=""
TYPE_SPEC=""
SEARCH_SPEC=""
LINES=""
DISABLE=0; ENABLE=0; CLEAR=0; SHOW_HELP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            # Argumento opcional
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                USER_SPEC="$2"
                shift 2
            else
                USER_SPEC="$(id -un)"   # usuario actual
                shift
            fi
            ;;
        --type)
            TYPE_SPEC="$2"; shift 2 ;;
        --search)
            SEARCH_SPEC="$2"; shift 2 ;;
        --lines)
            LINES="$2"; shift 2 ;;
        --disable)
            DISABLE=1; shift ;;
        --enable)
            ENABLE=1; shift ;;
        --clear)
            CLEAR=1; shift ;;
        --help)
            SHOW_HELP=1; shift ;;
        *)
            echo -e "${RED}Opción desconocida: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

if [ $SHOW_HELP -eq 1 ]; then show_help; exit 0; fi

# Acciones de control (usan el ámbito según EUID)
if [ $DISABLE -eq 1 ]; then
    touch "$(get_no_log_flag)"
    echo -e "${GREEN}Historial desactivado.${NC}"
    exit 0
fi

if [ $ENABLE -eq 1 ]; then
    rm -f "$(get_no_log_flag)"
    echo -e "${GREEN}Historial reactivado.${NC}"
    exit 0
fi

if [ $CLEAR -eq 1 ]; then
    LOG_FILE=$(get_log_file)
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}No hay historial.${NC}"
        exit 0
    fi
    read -p "¿Seguro que quieres borrar el historial? [s/N] " resp
    if [[ "$resp" =~ ^[sSyY] ]]; then
        > "$LOG_FILE"
        echo -e "${GREEN}Historial limpiado.${NC}"
    else
        echo -e "${YELLOW}Cancelado.${NC}"
    fi
    exit 0
fi

# Vista del historial
# Por defecto: historial global/root para todos
if [ -n "$USER_SPEC" ]; then
    USER_HOME=$(getent passwd "$USER_SPEC" | cut -d: -f6)
    if [ -z "$USER_HOME" ]; then
        echo -e "${RED}Error: Usuario '$USER_SPEC' no encontrado.${NC}"
        exit 1
    fi
    TARGET_LOG="$USER_HOME/.local/share/casata/HISTORY.log"
else
    TARGET_LOG="/usr/local/casata/HISTORY.log"
fi

if [ ! -f "$TARGET_LOG" ]; then
    echo -e "${YELLOW}No hay historial disponible.${NC}"
    exit 0
fi

# Construir filtro
if [ -n "$TYPE_SPEC" ]; then
    FILTER_CMD=(grep "type=$TYPE_SPEC" "$TARGET_LOG")
elif [ -n "$SEARCH_SPEC" ]; then
    FILTER_CMD=(grep -F "$SEARCH_SPEC" "$TARGET_LOG")
else
    FILTER_CMD=(cat "$TARGET_LOG")
fi

# Aplicar límite de líneas y paginador
if [ -n "$LINES" ]; then
    if ! [[ "$LINES" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}--lines debe ser un número.${NC}"
        exit 1
    fi
    "${FILTER_CMD[@]}" | tail -n "$LINES" | show_with_pager
else
    "${FILTER_CMD[@]}" | show_with_pager
fi
