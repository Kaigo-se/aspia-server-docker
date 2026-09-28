#!/bin/bash
#
# Imports the data of an Aspia Server 2.x (router.json, relay.json, router.pub, router.db3) into
# the running installation. The current data is backed up first; the 2.x configuration is
# converted by Aspia on start.
#
#   docker exec aspia-updater import-2x.sh <archive.zip|archive.tar.gz|directory>
#
# The path must be inside the project directory (it is mounted into the updater), relative paths
# are resolved against it, e.g.:  docker exec aspia-updater import-2x.sh import/aspia.zip

set -e

ASPIA_DIR=${ASPIA_DIR:-/opt/aspia}
CONTAINER=aspia-server
FILES=(router.json relay.json router.pub router.db3)

cd "${ASPIA_DIR}"

SOURCE="$1"
[[ -n "${SOURCE}" ]] || { echo "Usage: import-2x.sh <archive.zip|archive.tar.gz|directory>"; exit 1; }
[[ "${SOURCE}" == /* ]] || SOURCE="${ASPIA_DIR}/${SOURCE}"
[[ -e "${SOURCE}" ]] || { echo "${SOURCE} not found (it must be inside ${ASPIA_DIR})"; exit 1; }

COMPOSE="docker compose --project-directory ${ASPIA_DIR}"
PROJECT_NAME="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${CONTAINER}" 2>/dev/null)"
[[ -n "${PROJECT_NAME}" ]] && COMPOSE="${COMPOSE} -p ${PROJECT_NAME}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

case "${SOURCE}" in
    *.zip)          unzip -q "${SOURCE}" -d "${TMP}" ;;
    *.tar.gz|*.tgz) tar -xzf "${SOURCE}" -C "${TMP}" ;;
    *.tar)          tar -xf "${SOURCE}" -C "${TMP}" ;;
    *)              cp -r "${SOURCE}/." "${TMP}/" ;;
esac

declare -A FOUND
for file in "${FILES[@]}"; do
    FOUND[$file]="$(find "${TMP}" -type f -name "${file}" | head -n 1)"
    [[ -n "${FOUND[$file]}" ]] || { echo "${file} not found in ${SOURCE}"; exit 1; }
    echo "Found ${FOUND[$file]#"${TMP}"/}"
done

echo "Stopping the server..."
${COMPOSE} stop server

mkdir -p backups
BACKUP="backups/before-import_$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
tar -czf "${BACKUP}" data/config data/database
echo "Current data backed up to ${BACKUP}"

rm -rf data/config data/database
mkdir -p data/config data/database data/logs
cp "${FOUND[router.json]}" "${FOUND[relay.json]}" "${FOUND[router.pub]}" data/config/
cp "${FOUND[router.db3]}" data/database/

echo "Starting the server (the 2.x data is converted on start)..."
${COMPOSE} up -d --no-deps server

for _ in $(seq 1 36); do
    sleep 5
    if [[ "$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null)" == "healthy" ]]; then
        echo "Done: the server is healthy."
        docker logs --tail 15 "${CONTAINER}"
        exit 0
    fi
done

echo "The server is not healthy. Last log lines:"
docker logs --tail 40 "${CONTAINER}"
echo "The previous data is in ${BACKUP}"
exit 1
