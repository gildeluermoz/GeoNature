#!/bin/bash

SERVICES=("geonature" "geonature-worker" "taxhub" "usershub")

currentdir="${PWD}"
previousdir="$(dirname ${currentdir})/geonature_old"

echo "Nouveau dossier GeoNature : ${currentdir}"
echo "Ancien dossier GeoNature : ${previousdir}"

if [ ! -d backend ] || [ ! -d frontend ]; then
    echo "Vous ne semblez pas être dans un dossier GeoNature, arrêt."
    exit 1
fi

read -p "Appuyer sur une touche pour quitter. Appuyer sur Y ou y pour continuer. " choice
if [ "$choice" != 'y' ] && [ "$choice" != 'Y' ]; then
    echo "Arrêt de la migration."
    exit
else
    echo "Lancement de la migration..."
fi

echo "Arrêt des services…"
for service in ${SERVICES[@]}; do
    sudo systemctl stop "${service}"
done

echo "Copie des fichiers de configuration…"
# Copy all config files (installation, GeoNature, modules)
cp ${previousdir}/config/*.{ini,toml} ${currentdir}/config/
cp ${previousdir}/environ ${currentdir}/

if [ -d "${previousdir}/custm" ]; do
    echo "Copie de la customisation…"
    cp ${previousdir}/custom/* custom/
done

echo "Vérification de la robustesse de la SECRET_KEY…"
sk_len=$(grep -E '^SECRET_KEY' config/geonature_config.toml | tail -n 1 | sed 's/SECRET_KEY = ['\''"]\(.*\)['\''"]/\1/' | wc -c)
if [ $sk_len -lt 20 ]; then
    sed -i "s|^SECRET_KEY = .*$|SECRET_KEY = '`openssl rand -hex 32`'|" config/geonature_config.toml
fi

echo "Déplacement des anciens fichiers personnalisés du frontend..."
# before 2.12
if [ ! -f "${currentdir}/custom/css/frontend.css" ] && [ -f "${previousdir}/frontend/src/assets/custom.css" ]; then
  mkdir -p "${currentdir}/custom/css/"
  cp "${previousdir}/frontend/src/assets/custom.css" "${currentdir}/custom/css/frontend.css"
fi
# before 2.7
if [ ! -f "${currentdir}/custom/css/frontend.css" ] && [ -f "${previousdir}/frontend/src/custom/custom.scss" ]; then
  mkdir -p "${currentdir}/custom/css/"
  cp "${previousdir}/frontend/src/custom/custom.scss" "${currentdir}/custom/css/frontend.css"
fi
# before 2.12
if [ ! -f "${currentdir}/custom/images/favicon.ico" ] && [ -f "${previousdir}/frontend/src/favicon.ico" ] \
    && cmd -s "${previousdir}/frontend/src/favicon.ico" "${currentdir}/backend/static/images/favicon.ico"; then
  mkdir -p "${currentdir}/custom/images/"
  cp "${previousdir}/frontend/src/favicon.ico" "${currentdir}/custom/images/favicon.ico"
fi

echo "Déplacement des anciens fichiers static vers les médias …"
cd "${previousdir}/backend"
mkdir -p media
if [ -d static/medias ]; then mv static/medias media/attachments; fi  # medias becomes attachments
if [ -d static/pdf ]; then mv static/pdf media/pdf; fi
if [ -d static/exports ]; then mv static/exports media/exports; fi
if [ -d static/geopackages ]; then mv static/geopackages media/geopackages; fi
if [ -d static/shapefiles ]; then mv static/shapefiles media/shapefiles; fi
if [ -d static/mobile ]; then mv static/mobile media/mobile; fi


echo "Mise à jour de node si nécessaire …"
cd "${currentdir}"/frontend
export NVM_DIR="$HOME/.nvm"
 [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install
nvm use

echo "Installation des dépendances node du frontend …"
npm ci --only=prod

echo "Installation des dépendances node du backend …"
cd ${currentdir}/backend/static
npm ci --only=prod


echo "Mise à jour du backend …"
cd "${currentdir}/install"
./01_install_backend.sh
source venv/bin/activate

echo "Installation des modules externes …"
if [ -d "${previousdir}/external_modules/" ]; then
    # Modules before 2.11
    cd "${currentdir}/backend"
    for module in ${previousdir}/external_modules/*; do
        if [ ! -L "${module}" ]; then
            echo "N’est pas un lien symbolique, ignore : ${module}"
            continue
        fi
        name=$(basename ${module})
        echo "Installation du module ${name} …"
        target=$(readlink ${module})
        geonature install-gn-module "${target}" "${name^^}" --build=false --upgrade-db=false
    done
fi
cd "${currentdir}/frontend/external_modules"
for module in ${previousdir}/frontend/external_modules/*; do
    if [ ! -L "${module}" ]; then
        echo "N’est pas un lien symbolique, ignore : ${module}"
        continue
    fi
    name=$(basename ${module})
    echo "Installation du module ${name} …"
    target=$(readlink ${module})
    if [ "$(basename ${target})" != "frontend" ]; then
        "Erreur, ne pointe pas vers un dossier frontend : ${module}"
        exit 1
    fi
    module_dir=$(dirname ${target})
    geonature install-gn-module "${module_dir}" "${name^^}" --build=false --upgrade-db=false
done

echo "Mise à jour des scripts systemd…"
cd ${currentdir}/install
./02_configure_systemd.sh
cd ${currentdir}/

# before GeoNature 2.10
if [ -f "/var/log/geonature.log" ]; then
    echo "Déplacement des fichiers de logs /var/log/geonature.log → /var/log/geonature/geonature.log …"
    sudo mkdir -p /var/log/geonature/
    sudo mv /var/log/geonature.log /var/log/geonature/geonature.log
    sudo chown $USER: -R /var/log/geonature/
fi


if [[ ! -f "${currentdir}/frontend/src/assets/config.json" ]]; then
  echo "Création du fichiers de configuration du frontend …"
  cp -n "${currentdir}/src/assets/config.sample.json" "${currentdir}/src/assets/config.json"
fi
echo "Mise à jour de la variable API_ENDPOINT dans le fichier de configuration du frontend …"
api_end_point=$(geonature get-config API_ENDPOINT)
if [ ! -z "$api_end_point" ]; then
    # S’il une erreur se produit durant la récupération de la variable depuis GeoNature,
    # utilisation de la valeur en provenant du fichier settings.ini
    API_ENDPOINT="$my_url"
fi
sed -i 's|"API_ENDPOINT": .*$|"API_ENDPOINT" : "'${api_end_point}'"|' "${currentdir}/frontend/src/assets/config.json"

echo "Mise à jour des fichiers de configuration frontend et rebuild du frontend…"
geonature update-configuration

echo "Mise à jour de la base de données…"
# Si occtax est installé, alors il faut le mettre à jour en version 4c97453a2d1a (min.)
# *avant* de mettre à jour GeoNature (contrainte NOT NULL sur id_source dans la synthèse)
# Voir https://github.com/PnX-SI/GeoNature/issues/2186#issuecomment-1337684933
geonature db heads | grep "(occtax)" > /dev/null && geonature db upgrade occtax@4c97453a2d1a
geonature db autoupgrade || exit 1
geonature upgrade-modules-db

echo "Mise à jour de la configuration Apache …"
cd "${currentdir}/install/"
./06_configure_apache.sh
sudo apachectl && sudo systemctl reload apache2

echo "Redémarrage des services…"
for service in ${SERVICES[@]}; do
    sudo systemctl start "${service}"
done

deactivate

echo "Migration terminée"
