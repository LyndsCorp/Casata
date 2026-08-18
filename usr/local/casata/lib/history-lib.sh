#!/bin/bash
# /usr/local/casata/lib/history-lib.sh
# Librería central de logging de Casata (cápsula del tiempo)

# Copyright (C) 2026 David Baña Szymaniak

CASATA_ROOT="${CASATA_ROOT:-/usr/local/casata}"

# Obtener archivo de historial según ámbito
get_log_file() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        echo "/usr/local/casata/HISTORY.log"
    else
        echo "$HOME/.local/share/casata/HISTORY.log"
    fi
}

get_no_log_flag() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        echo "/usr/local/casata/NO_LOG"
    else
        echo "$HOME/.local/share/casata/NO_LOG"
    fi
}

# Escribe un evento en el historial
log_event() {
    local type="$1"; shift
    local message="$*"

    local no_log_flag
    no_log_flag="$(get_no_log_flag)"
    [ -f "$no_log_flag" ] && return 0

    local log_file
    log_file="$(get_log_file)"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

    local user
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        user="root(sudo:${SUDO_USER})"
    elif [ -n "${SUDO_USER:-}" ]; then
        user="${SUDO_USER}"
    else
        user="${USER:-unknown}"
    fi

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[$timestamp] user=$user type=$type $message" >> "$log_file"
}

log_command_start() {
    log_event "COMMAND" "cmd=\"$*\""
}

log_command_end() {
    local exit_code="$1"; shift
    local result="SUCCESS"
    [ "$exit_code" -eq 0 ] || result="FAILURE"
    log_event "COMMAND_RESULT" "exit_code=$exit_code result=$result cmd=\"$*\""
}

log_dependencies_system() {
    local manager="$1"; shift
    local packages="$*"
    log_event "DEPENDENCIES_SYSTEM" "manager=$manager packages=\"$packages\""
}

log_dependencies_pip() {
    log_event "DEPENDENCIES_PIP" "packages=\"$*\""
}

log_dependencies_casata() {
    log_event "DEPENDENCIES_CASATA" "packages=\"$*\""
}

log_download() {
    local url="$1"; local dest="$2"; local status="$3"
    log_event "DOWNLOAD" "url=\"$url\" dest=\"$dest\" status=$status"
}

log_sha256() {
    local file="$1"; local status="$2"
    log_event "SHA256" "file=\"$file\" status=$status"
}

log_symlink_created() {
    local name="$1"; local target="$2"; local dest="$3"
    log_event "SYMLINK_CREATED" "name=\"$name\" target=\"$target\" dest=\"$dest\""
}

log_symlink_removed() {
    local name="$1"; local target="$2"
    log_event "SYMLINK_REMOVED" "name=\"$name\" target=\"$target\""
}

log_package_installed() {
    local pkg="$1"; local version="$2"; local result="$3"
    log_event "PACKAGE_INSTALLED" "package=\"$pkg\" version=\"$version\" result=$result"
}

log_package_removed() {
    local pkg="$1"; local scope="$2"; local result="$3"
    log_event "PACKAGE_REMOVED" "package=\"$pkg\" scope=$scope result=$result"
}

log_repo_updated() {
    local repo="$1"; local status="$2"
    log_event "REPO_UPDATED" "repo=\"$repo\" status=$status"
}

log_repo_added() {
    local repo="$1"; local status="$2"
    log_event "REPO_ADDED" "repo=\"$repo\" status=$status"
}

log_cleanup_path() {
    local path="$1"
    log_event "CLEANUP" "path=\"$path\""
}

log_external_file() {
    local url="$1"; local dest="$2"
    log_event "EXTERNAL_FILE" "url=\"$url\" dest=\"$dest\""
}
