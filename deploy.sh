#!/usr/bin/env bash
# Déploiement local : ./deploy.sh (Docker Desktop et accès SSH/SFTP au NAS).
# Le compose est synchronisé ; le fichier env du NAS est conservé.
set -euo pipefail

cd "$(dirname "$0")"
remote_dir=${DEPLOY_REMOTE_DIR:-/volume1/docker/captain_homework}
transfer_dir=${DEPLOY_SFTP_DIR:-/docker/captain_homework}
remote_host=${DEPLOY_HOST:?Définir DEPLOY_HOST (utilisateur@serveur) avant le déploiement}
remote_port=${DEPLOY_PORT:-22}
platform=${DOCKER_PLATFORM:-linux/amd64}

for tool in docker ssh scp; do
  command -v "$tool" >/dev/null || { echo "Commande manquante : $tool" >&2; exit 1; }
done
docker info >/dev/null
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/captain_homework-deploy.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
archive="$staging_dir/captain_homework-image.tar.partial"

# Vérifier la destination avant de construire et transférer l'image.
printf -v prepare_command 'bash -c %q -- %q' 'set -eu; mkdir -p -- "$1"; test -w "$1"; test -r "$1/env"' "$remote_dir"
ssh -p "$remote_port" "$remote_host" "$prepare_command"

echo "Construction de l’image ${platform}…"
docker buildx build --platform "$platform" --load -t captain_homework:local .
echo 'Export local de l’image…'
docker save -o "$archive" captain_homework:local
cp docker-compose.yml "$staging_dir/docker-compose.yml.partial"
echo 'Transfert de l’image et du compose vers le NAS…'
# OpenSSH scp utilise SFTP par défaut ; sa racine diffère du chemin SSH du NAS.
scp -P "$remote_port" "$archive" "$staging_dir/docker-compose.yml.partial" "$remote_host:$transfer_dir/"

remote_script=$(cat <<'REMOTE'
set -euo pipefail
export PATH="/usr/local/bin:/var/packages/ContainerManager/target/usr/bin:$PATH"
cd "$1"
test -r env
test -r docker-compose.yml.partial
test -s captain_homework-image.tar.partial
mv -f -- captain_homework-image.tar.partial captain_homework-image.tar
mv -f -- docker-compose.yml.partial docker-compose.yml

# Compose lit .env pour les chemins et l'identité Unix ; env reste réservé à l'app.
if [[ ! -e .env ]]; then
  (umask 077; printf 'DATA_DIR=.\nAPP_UID=%s\nAPP_GID=%s\nDOCKER_PLATFORM=%s\n' "$(id -u)" "$(id -g)" "$2" > .env)
fi

# Ne jamais masquer un historique existant en remplaçant son volume par un dossier vide.
old_container=$(sudo docker compose -p captain_homework ps -aq captain_homework)
if [[ -n "$old_container" ]]; then
  old_volume=$(sudo docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' "$old_container")
  if [[ -n "$old_volume" ]]; then
    echo "Migration nécessaire : le conteneur utilise encore le volume $old_volume. Sauvegarder et transférer les données du volume vers DATA_DIR avant de continuer." >&2
    exit 1
  fi
fi

echo 'Chargement de la nouvelle image…'
sudo docker load -i captain_homework-image.tar
echo 'Vérification des permissions du dossier SQLite…'
sudo docker compose -p captain_homework run --rm --no-deps --entrypoint sh captain_homework -c 'test -w /app/data || { echo "DATA_DIR doit être accessible en écriture à APP_UID:APP_GID (voir .env)." >&2; exit 1; }'
echo 'Recréation des conteneurs avec la nouvelle image…'
sudo docker compose -p captain_homework up -d --force-recreate
container=$(sudo docker compose -p captain_homework ps -q captain_homework)
for attempt in $(seq 1 30); do
  state=$(sudo docker inspect --format '{{.State.Health.Status}}' "$container")
  if [[ "$state" == "healthy" ]]; then
    echo 'Captain Homework est en ligne et sain.'
    exit 0
  fi
  if [[ "$state" == "unhealthy" ]]; then break; fi
  sleep 2
done
echo 'Le nouveau conteneur ne répond pas au contrôle de santé. Vérifier ses logs.' >&2
exit 1

REMOTE
)

# Un terminal distant permet à SSH et sudo de demander leur mot de passe.
printf -v remote_command 'bash -c %q -- %q %q' "$remote_script" "$remote_dir" "$platform"
ssh -t -p "$remote_port" "$remote_host" "$remote_command"
