#!/bin/bash

# Script de desinstalacion de Casata
# GPL v3, Aros Legendarios, David Baña Szymaniak

NoInstalar="0" # otro bool value
YaMostrasteHelp="0"
Purgar="1"

MostrarHelp() {
    if [ "$YaMostrasteHelp" == "0" ]; then
        echo "Casata Uninstaller Help"
        echo "---------------------"
        echo ""
        echo "Los flags son:"
        echo "  --help (-h): muestra esta ayuda."
        echo "  --version (-v): muestra la versión que tienes en el paquete localmente."
        echo "  --no-purge (-n): Solo elimina el comando -casata-, pero Casata sigue instalado."
        echo "  --license (-l): muestra la licencia, proyecto y autor del código."
        echo ""
        echo "Por cierto: ejecuta -./uninstall.sh --flag- con la terminal abierta en la carpeta de este script."
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

    --no-purge|-n)
        Purgar="0"
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
    #exit 1
fi

if [ "$NoInstalar" == "0" ]; then
    if [ "$Purgar" == "1" ]; then
        #eliminar el script para que sea un comando
        echo "Eliminando el router (casata.sh) de /usr/bin/casata..."
        rm -f /usr/bin/casata

        #eliminar el root de Casata
        echo "Eliminando root de Casata de /usr/local/casata/..."
        rm -rf /usr/local/casata/
    else
        echo "Eliminando SOLO el router (comando) de Casata (/usr/bin/casata)..."
        rm -f /usr/bin/casata
    fi

    echo ""
    echo "----------------------------------------------------------------------------------"
    echo "¡Casata desinstalado correctamente!"

    exit 0 #todo salio bien :)
fi
