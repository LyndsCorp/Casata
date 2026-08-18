#!/bin/bash
# /usr/local/casata/modules/history.sh

# Copyright (C) 2026 David Baña Szymaniak

CASATA_ROOT="/usr/local/casata"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -f "$CASATA_ROOT/lib/history-lib.sh" ]; then
    source "$CASATA_ROOT/lib/history-lib.sh"
fi

show_help() {
    cat <<EOF
Uso: casata history [OPCIONES]

Opciones:
  --date <fecha>      Ver solo entradas de una fecha (DD-MM-YYYY o D-M-YYYY)
  --user [nombre]     Ver historial de un usuario. Sin nombre usa el actual.
                      Por defecto se muestra el historial global/root.
  --type <tipo>       Filtrar por tipo (p. ej. PAQUETE_INSTALADO, ENLACE_CREADO, etc.)
  --search <texto>    Buscar texto en las líneas
  --lines N           Mostrar solo las N entradas más recientes
  --disable           Desactivar el registro de historial
  --enable            Reactivar el registro de historial
  --clear             Limpiar el historial (pide confirmación)
  --help              Mostrar esta ayuda

Sin opciones, muestra el historial global (de root) del más reciente al más antiguo.
EOF
}

# Normalizar fecha DD-MM-YYYY a YYYY-MM-DD
normalize_date() {
    local input="$1"
    input="${input//\//-}"
    input="${input//./-}"
    IFS='-' read -ra parts <<< "$input"
    [ ${#parts[@]} -ne 3 ] && return 1
    local day=$(printf "%02d" "$((10#${parts[0]}))" 2>/dev/null)
    local month=$(printf "%02d" "$((10#${parts[1]}))" 2>/dev/null)
    local year="${parts[2]}"
    if [ -z "$day" ] || [ -z "$month" ] || ! [[ "$year" =~ ^[0-9]{4}$ ]]; then
        return 1
    fi
    echo "${year}-${month}-${day}"
}

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
DATE_SPEC=""
TYPE_SPEC=""
SEARCH_SPEC=""
LINES=""
DISABLE=0; ENABLE=0; CLEAR=0; SHOW_HELP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                USER_SPEC="$2"
                shift 2
            else
                USER_SPEC="$(id -un)"
                shift
            fi
            ;;
        --date|--fecha|--day)
            DATE_SPEC="$2"
            shift 2
            ;;
        --type)
            TYPE_SPEC="$2"
            shift 2
            ;;
        --search)
            SEARCH_SPEC="$2"
            shift 2
            ;;
        --lines)
            LINES="$2"
            shift 2
            ;;
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

# Acciones de control
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

# Determinar archivo a mostrar
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

# Normalizar fecha si se especificó
NORMALIZED_DATE=""
if [ -n "$DATE_SPEC" ]; then
    NORMALIZED_DATE="$(normalize_date "$DATE_SPEC")"
    if [ -z "$NORMALIZED_DATE" ]; then
        echo -e "${RED}Error: Fecha inválida '$DATE_SPEC'. Use DD-MM-YYYY.${NC}"
        exit 1
    fi
fi

# Límite de líneas (0 = sin límite)
LIMIT=0
if [ -n "$LINES" ]; then
    if ! [[ "$LINES" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}--lines debe ser un número.${NC}"
        exit 1
    fi
    LIMIT="$LINES"
fi

# Mostrar historial aplicando filtros de forma segura
# Se lee línea por línea y se filtran por tipo, búsqueda y fecha.
# El orden es el del archivo (más reciente arriba).
{
    count=0
    while IFS= read -r line; do
        # Aplicar filtro por tipo (búsqueda exacta de la etiqueta)
        if [ -n "$TYPE_SPEC" ] && [[ "$line" != *"[$TYPE_SPEC]"* ]]; then
            continue
        fi

        # Aplicar filtro por texto (búsqueda literal)
        if [ -n "$SEARCH_SPEC" ] && [[ "$line" != *"$SEARCH_SPEC"* ]]; then
            continue
        fi

        # Aplicar filtro por fecha (formato [YYYY-MM-DD ...)
        if [ -n "$NORMALIZED_DATE" ] && [[ "$line" != \[$NORMALIZED_DATE\ * ]]; then
            continue
        fi

        # Si la línea pasa todos los filtros, mostrarla
        echo "$line"
        count=$((count + 1))

        # Si hay límite y ya lo alcanzamos, salir del bucle
        if [ "$LIMIT" -gt 0 ] && [ "$count" -ge "$LIMIT" ]; then
            break
        fi
    done < "$TARGET_LOG"
} | show_with_pager
