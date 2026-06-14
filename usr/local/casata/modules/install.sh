#!/bin/bash
# /usr/local/casata/modules/install.sh

GLOBAL_ROOT="/usr/local/casata"
DATA_DIR="$GLOBAL_ROOT/data"

# Colores corregidos
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parsear flags y nombre del paquete
AUTO_YES=0
DOWNLOAD_ONLY=0
USER_INSTALL=0
PKG_NAME=""

for arg in "$@"; do
    if [ "$arg" == "-y" ]; then AUTO_YES=1;
    elif [ "$arg" == "-d" ]; then DOWNLOAD_ONLY=1;
    elif [ "$arg" == "--user" ]; then USER_INSTALL=1;
    else PKG_NAME=$arg; fi
done

[ -z "$PKG_NAME" ] && { echo -e "${RED}Error: Falta el nombre del paquete.${NC}"; exit 1; }

# Configurar rutas y validación
if [ $USER_INSTALL -eq 1 ]; then
    APPS_DIR="$HOME/.local/casata/apps"
    GUIDE_TARGET="GUIDE-USER.json"
    INSTALL_TYPE="Usuario"
else
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: La instalación global requiere permisos de root.${NC}"
        exit 1
    fi
    APPS_DIR="$GLOBAL_ROOT/apps"
    GUIDE_TARGET="GUIDE.json"
    INSTALL_TYPE="Global"
fi

mkdir -p "$APPS_DIR"
APP_DIR="$APPS_DIR/${PKG_NAME}"

# 1. BUSCAR EL ARCHIVO EN LOS REPOSITORIOS (Para obtener la URL de descarga)
REPO_FILE=$(find "$GLOBAL_ROOT/repos" -name "${PKG_NAME}.json" -print -quit)

if [ -z "$REPO_FILE" ] || [ ! -f "$REPO_FILE" ]; then
    echo -e "${RED}Error: El paquete '$PKG_NAME' no se encontró en ningún repositorio local (/usr/local/casata/repos/).${NC}"
    exit 1
fi

# Leer download_url desde el archivo del repositorio
REPO_JSON=$(cat "$REPO_FILE")
DOWNLOAD_URL=$(echo "$REPO_JSON" | jq -r '.download_url // empty')

# 2. LEER LA INFORMACIÓN DE METADATOS (Desde la carpeta data/)
PKG_FILE="$DATA_DIR/${PKG_NAME}.json"

if [ ! -f "$PKG_FILE" ]; then
    echo -e "${RED}Error: No se encontró la información del paquete en la base de datos local ($PKG_FILE).${NC}"
    exit 1
fi

PKG_INFO=$(cat "$PKG_FILE")

# Extraer metadatos informativos para la interfaz
PKG_VERSION=$(echo "$PKG_INFO" | jq -r '.version // "desconocida"')
PKG_SIZE=$(echo "$PKG_INFO" | jq -r '.size // "desconocido"')
PKG_DESCRIPTION=$(echo "$PKG_INFO" | jq -r '.description // ""')
PKG_USAGE=$(echo "$PKG_INFO" | jq -r '.usage // ""')
PKG_DEPENDENCIES=$(echo "$PKG_INFO" | jq -r '.dependencies[]? // empty')

# Mostrar información del paquete
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}Información del Paquete${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "  ${YELLOW}Nombre:${NC} $PKG_NAME"
echo -e "  ${YELLOW}Versión:${NC} $PKG_VERSION"
echo -e "  ${YELLOW}Tamaño:${NC} $PKG_SIZE"
if [ ! -z "$PKG_DESCRIPTION" ]; then
    echo -e "  ${YELLOW}Descripción:${NC} $PKG_DESCRIPTION"
fi
if [ ! -z "$PKG_USAGE" ]; then
    echo -e "  ${YELLOW}Uso:${NC} $PKG_USAGE"
fi

# Mostrar y validar dependencias
if [ ! -z "$PKG_DEPENDENCIES" ]; then
    echo -e "\n${YELLOW}Dependencias a instalar:${NC}"
    echo "$PKG_DEPENDENCIES" | while read -r dep; do
        echo -e "  • $dep"
    done
else
    echo -e "\n${YELLOW}No hay dependencias definidas.${NC}"
fi

echo -e "${GREEN}════════════════════════════════════════${NC}\n"

# Pregunta confirmación
if [ $AUTO_YES -eq 0 ]; then
    read -p "¿Deseas proceder con la instalación ($INSTALL_TYPE) de $PKG_NAME? [S/n] " response
    [[ "$response" =~ ^([nN][oO]|[nN])$ ]] && { echo "Aborted."; exit 0; }
fi

# Validar que efectivamente obtuvimos una URL de descarga válida desde el repositorio
[ -z "$DOWNLOAD_URL" ] && { echo -e "${RED}Error: URL de descarga no encontrada en el archivo del repositorio.${NC}"; exit 1; }

echo -e "${GREEN}Preparando instalación de $PKG_NAME...${NC}"

# Instalar dependencias del sistema
if [ ! -z "$PKG_DEPENDENCIES" ]; then
    echo -e "\n${YELLOW}Instalando dependencias del sistema...${NC}"

    DEPS_STRING=$(echo "$PKG_DEPENDENCIES" | tr '\n' ' ')

    if [ $USER_INSTALL -eq 1 ]; then
        echo -e "${YELLOW}Nota: Usuario no-root detectado. Usando sudo para instalar dependencias.${NC}"
        sudo apt-get update -qq && sudo apt-get install -y $DEPS_STRING
    else
        apt-get update -qq && apt-get install -y $DEPS_STRING
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Falló la instalación de dependencias.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Dependencias instaladas correctamente.${NC}\n"
else
    echo -e "${YELLOW}No hay dependencias que instalar.${NC}\n"
fi

# --- DESCARGA Y EXTRACCIÓN ---

# 1. Crear el directorio destino de la aplicación en "apps"
[ -d "$APP_DIR" ] && rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

# 2. Extraer el nombre real del archivo de la URL
ARCHIVE_NAME=$(basename "$DOWNLOAD_URL")
ARCHIVE_NAME="${ARCHIVE_NAME%%\?*}"

# 3. Definir la ruta donde se guardará el archivo comprimido
ARCHIVE_PATH="$APP_DIR/$ARCHIVE_NAME"

# Directorio temporal para la extracción limpia
EXTRACT_DIR=$(mktemp -d)

echo -e "${GREEN}Descargando archivo comprimido en: ${YELLOW}$APP_DIR${NC}"
wget -q --show-progress -O "$ARCHIVE_PATH" "$DOWNLOAD_URL" || { echo -e "${RED}Error descarga.${NC}"; rm -rf "$APP_DIR" "$EXTRACT_DIR"; exit 1; }

# Extraer el archivo que ahora reside en apps/
if [[ "$ARCHIVE_NAME" == *.zip ]]; then
    unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR"
elif [[ "$ARCHIVE_NAME" == *.tar.gz || "$ARCHIVE_NAME" == *.tgz ]]; then
    tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
elif [[ "$ARCHIVE_NAME" == *.tar.xz ]]; then
    tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
else
    echo -e "${RED}Formato no soportado.${NC}"
    rm -rf "$APP_DIR" "$EXTRACT_DIR"
    exit 1
fi

# Encontrar la carpeta de código fuente dentro de la extracción
SRC_DIR=$(find "$EXTRACT_DIR" -name "VERSION" -exec dirname {} \; | head -n 1)
[ -z "$SRC_DIR" ] && SRC_DIR=$(ls -d "$EXTRACT_DIR"/*/ 2>/dev/null | head -n 1)
[ -z "$SRC_DIR" ] && SRC_DIR="$EXTRACT_DIR"

# Mover el contenido extraído a la carpeta de la app junto al archivo comprimido
mv "$SRC_DIR"/* "$APP_DIR/" 2>/dev/null || mv "$SRC_DIR/".* "$APP_DIR/" 2>/dev/null

# Limpiar el directorio de extracción (el ZIP/TAR.GZ se queda intacto en $APP_DIR)
rm -rf "$EXTRACT_DIR"

if [ $DOWNLOAD_ONLY -eq 1 ]; then
    echo -e "${YELLOW}Modo -d: Descargado y extraído en $APP_DIR sin enlaces.${NC}"
    exit 0
fi

# --- VINCULACIÓN DE ENLACES ---

echo " -> Configurando enlaces (seguridad activa)..."
GUIDE_FILE="$APP_DIR/$GUIDE_TARGET"

if [ -f "$GUIDE_FILE" ]; then
    # Solucionado el problema del Subshell para que exit 1 funcione correctamente
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

        # --- BLOQUE DE SEGURIDAD ---
        if [ -e "$TARGET_LINK" ] || [ -L "$TARGET_LINK" ]; then
            if [ -L "$TARGET_LINK" ] && [ "$(readlink "$TARGET_LINK")" == "$APP_DIR/$FILE" ]; then
                echo -e "   [=] Ya existe enlace correcto: $LINK_NAME"
            else
                echo -e "${RED}!!! ALERTA DE SEGURIDAD !!!${NC}"
                echo -e "${RED}El archivo '$TARGET_LINK' ya existe y no pertenece a este paquete.${NC}"
                echo -e "${RED}Abortando instalación para prevenir sobreescritura maliciosa.${NC}"
                rm -rf "$APP_DIR"
                exit 1
            fi
        else
            ln -s "$APP_DIR/$FILE" "$TARGET_LINK"

            if [ "$EXECUTABLE" == "true" ]; then
                chmod +x "$APP_DIR/$FILE"
                echo -e "   [+] Enlazado: ${YELLOW}$LINK_NAME${NC} -> $DEST (ejecutable)"
            else
                echo -e "   [+] Enlazado: ${YELLOW}$LINK_NAME${NC} -> $DEST"
            fi
        fi
    done < <(jq -c '.links[]' "$GUIDE_FILE")
else
    echo -e "${YELLOW}Aviso: No se encontró $GUIDE_TARGET.${NC}"
fi

echo -e "\n${GREEN}¡$PKG_NAME instalado correctamente!${NC}"
