#!/bin/bash

# Script de instalacion de Casata desde ZIP
# GPL v3, Aros Legendarios, David Baña Szymaniak

Full="0" # bool value, 0 = false y 1 = true
NoInstalar="0" # otro bool value
YaMostrasteHelp="0"

MostrarHelp() {
    if [ "$YaMostrasteHelp" == "0" ]; then
        echo "Casata Installer Help"
        echo "---------------------"
        echo ""
        echo "Los flags son:"
        echo "  --help (-h): muestra esta ayuda."
        echo "  --version (-v): muestra la versión que tienes en el paquete localmente."
        echo "  --full (-f): Te instala la última versión de Casata, descargándola de internet."
        echo "  --license (-l): muestra la licencia, proyecto y autor del código."
        echo "  --gpl (--gplv3): muestra el texto completo de la licencia GPL v3."
        echo ""
        echo "Por cierto: ejecuta -./install.sh --flag- con la terminal abierta en la carpeta de este script."
        YaMostrasteHelp="1"
      fi
}

case "$1" in # aqui se definen los flags
    --help|-h)
        MostrarHelp
        NoInstalar="1"
        ;;

    --version|-v)
        echo "La versión que vas a instalar (la que tienes aquí localmente) es la:"
        cat usr/local/casata/VERSION
        NoInstalar="1"
        ;;

    --full|-f)
        echo "FLAG: Instalando versión completa con internet. Local como fallback."
        Full="1"
        ;;

    #flags de licencia
    --license|-l)
        echo "Licencia GPL v3, Aros Legendarios, David Baña Szymaniak."
        NoInstalar="1"
        ;;
    --gpl|--gplv3)
        cat usr/local/casata/LICENSE
        NoInstalar="1"
        ;;
    *)
        ;;
esac


if [ "$EUID" -ne 0 ]; then
    MostrarHelp
    exit 1
fi

if [ "$NoInstalar" == "0" ]; then
    #copiar el script para que sea un comando
    echo "Copiando el router (casata.sh) al /usr/bin/casata para que sea un comando en la terminal..."
    cp usr/bin/casata.sh /usr/bin/casata

    echo "Dándole permisos de ejecución a /usr/bin/casata para que reconozca el comando..."
    chmod +x /usr/bin/casata

    #copiar el root de Casata
    echo "Copiando root de Casata en /usr/local/casata/..."
    cp -r usr/local/casata/ /usr/local/

    echo "Dando permisos de ejecución a los módulos de Casata por si acaso..."
    chmod +x /usr/local/casata/modules/*

    echo ""

    if [ "$Full" == "1" ]; then
        echo "Actualizando Casata si se puede..."
        casata install casata -y && casata add oficial forge community others || echo "No se pudo actualizar. Revisa tu conexión a internet o firewall a github.com."
    fi

    echo ""
    echo "----------------------------------------------------------------------------------"
    echo "¡Casata instalado correctamente!"
    echo "Versión:"
    cat /usr/local/casata/VERSION

    if [ "$Full" == "0" ]; then
        echo ""
        echo "Te recomiendo ejecutar -sudo casata add oficial forge community others- para añadir los repositorios principales."
        echo "¡Prueba a escribir -casata- en tu terminal!"
    fi

    exit 0 #todo salio bien :)
fi
