#!/bin/bash
#
# Updates the Aspia Server container.
#
#   docker exec aspia-updater update.sh                                   regular check (same as the daily one)
#   docker exec -e MIN_AGE_DAYS=0 aspia-updater update.sh                 install a fresh release right away
#   docker exec -e FORCE_VERSION=3.0.18 aspia-updater update.sh           switch to exactly this version
#   docker exec -e DRY_RUN=1 -e MIN_AGE_DAYS=0 aspia-updater update.sh    only report
#
# 1. Finds the target version: the latest release of github.com/dchapyshev/aspia that is at least
#    MIN_AGE_DAYS old (or FORCE_VERSION).
# 2. Pulls its image from the registry (or builds it when compose.build.yaml is enabled) while the
#    current version keeps running. A rebuilt image of the same version (security updates) counts too.
# 3. Stops the server, backs up data/config and data/database, starts the new image and waits until
#    the container is healthy. Otherwise restores the backup and the previous image.
# 4. Removes old images, backups beyond KEEP_BACKUPS and Aspia logs older than LOG_RETENTION_DAYS,
#    then updates the updater itself (SELF_UPDATE=1).

ASPIA_DIR=${ASPIA_DIR:-/opt/aspia}
MIN_AGE_DAYS=${MIN_AGE_DAYS:-2}
KEEP_BACKUPS=${KEEP_BACKUPS:-10}
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-30}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
ROLLBACK_TIMEOUT=${ROLLBACK_TIMEOUT:-180}
SELF_UPDATE=${SELF_UPDATE:-1}
DRY_RUN=${DRY_RUN:-0}

REPO=dchapyshev/aspia
SERVICE=server
CONTAINER=aspia-server
UPDATER_CONTAINER=aspia-updater

ENV_FILE="${ASPIA_DIR}/.env"
BACKUP_DIR="${ASPIA_DIR}/backups"
LOG_FILE="${ASPIA_DIR}/update.log"
LOCK_DIR="${ASPIA_DIR}/.update.lock"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

fail() {
    log "ERROR: $*"
    exit 1
}

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found - ASPIA_DIR in .env must be the real path of the project"
    exit 1
fi
cd "${ASPIA_DIR}" || exit 1

# Registry credentials of the host (private images).
if [[ -f /run/host-docker/config.json ]]; then
    mkdir -p "${HOME}/.docker"
    cp /run/host-docker/config.json "${HOME}/.docker/config.json"
fi

COMPOSE="docker compose --project-directory ${ASPIA_DIR}"
# Use the project name of the running server (Synology Container Manager names projects itself).
PROJECT_NAME="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${CONTAINER}" 2>/dev/null)"
[[ -n "${PROJECT_NAME}" ]] && COMPOSE="${COMPOSE} -p ${PROJECT_NAME}"

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    fail "another update is running (remove ${LOCK_DIR} if it is stale)"
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT

# ---------- Helpers ----------

set_version() {
    sed -i "s/^ASPIA_VERSION=.*/ASPIA_VERSION=$1/" "${ENV_FILE}"
}

# service_image <service> <version>: image reference of a service for the given version
service_image() {
    ASPIA_VERSION="$2" ${COMPOSE} config --format json 2>/dev/null | jq -r ".services.$1.image"
}

# build mode when compose.build.yaml (or any build section) is enabled for the server
is_build_mode() {
    ${COMPOSE} config --format json 2>/dev/null | jq -e ".services.${SERVICE}.build" >/dev/null
}

image_id() {
    docker image inspect -f '{{.Id}}' "$1" 2>/dev/null
}

container_image_id() {
    docker inspect -f '{{.Image}}' "$1" 2>/dev/null
}

# wait_healthy <timeout>
wait_healthy() {
    local deadline=$((SECONDS + $1)) status
    while (( SECONDS < deadline )); do
        sleep 5
        status="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${CONTAINER}" 2>/dev/null)"
        [[ "${status}" == "running/healthy" ]] && return 0
    done
    log "Container state: ${status:-unknown}"
    return 1
}

# Replaces the updater container with its new image from a separate short-lived container,
# because a container cannot recreate itself.
self_update() {
    [[ "${SELF_UPDATE}" == "1" ]] || return 0
    is_build_mode && return 0

    local image current_id new_id
    image="$(service_image updater "${CURRENT}")"
    [[ -n "${image}" && "${image}" != "null" ]] || return 0

    ${COMPOSE} pull --quiet updater >>"${LOG_FILE}" 2>&1 || { log "Unable to pull ${image}"; return 0; }

    current_id="$(container_image_id "${UPDATER_CONTAINER}")"
    new_id="$(image_id "${image}")"
    [[ -z "${current_id}" || -z "${new_id}" || "${current_id}" == "${new_id}" ]] && return 0

    log "New updater image, restarting the updater"
    docker run -d --rm --name aspia-updater-selfupdate \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${ASPIA_DIR}:${ASPIA_DIR}" \
        --entrypoint sh "${image}" \
        -c "sleep 5; ${COMPOSE} up -d --no-deps updater" >>"${LOG_FILE}" 2>&1
}

# ---------- Housekeeping ----------

find data/logs -type f -name '*.log' -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null

# ---------- Target version ----------

CURRENT="$(sed -n 's/^ASPIA_VERSION=//p' "${ENV_FILE}" | tr -d '[:space:]')"
[[ -n "${CURRENT}" ]] || fail "ASPIA_VERSION is not set in ${ENV_FILE}"

TARGET="${CURRENT}"

if [[ -n "${FORCE_VERSION}" ]]; then
    TARGET="${FORCE_VERSION#v}"
    log "Forced version: ${TARGET}"
else
    RELEASE="$(curl -fsSL --max-time 30 "https://api.github.com/repos/${REPO}/releases/latest")"
    if [[ -z "${RELEASE}" ]]; then
        log "WARNING: unable to get the latest release from GitHub"
    else
        LATEST="$(echo "${RELEASE}" | jq -r '.tag_name // empty' | sed 's/^v//')"
        PUBLISHED="$(echo "${RELEASE}" | jq -r '.published_at // empty')"
        NEWEST="$(printf '%s\n%s\n' "${CURRENT}" "${LATEST}" | sort -V | tail -n 1)"

        if [[ -n "${LATEST}" && "${LATEST}" != "${CURRENT}" && "${NEWEST}" == "${LATEST}" ]]; then
            AGE_DAYS=$(( ($(date +%s) - $(date -d "${PUBLISHED}" +%s)) / 86400 ))
            if (( AGE_DAYS < MIN_AGE_DAYS )); then
                log "Release ${LATEST} is ${AGE_DAYS} day(s) old, it will be installed when it is ${MIN_AGE_DAYS} day(s) old"
            else
                TARGET="${LATEST}"
            fi
        fi
    fi
fi

[[ "${TARGET}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "unexpected version format: ${TARGET}"

TARGET_IMAGE="$(service_image "${SERVICE}" "${TARGET}")"
[[ -n "${TARGET_IMAGE}" && "${TARGET_IMAGE}" != "null" ]] || fail "unable to resolve the server image (check compose.yaml and .env)"

if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: current ${CURRENT}, target ${TARGET} (${TARGET_IMAGE}), mode: $(is_build_mode && echo build || echo pull)"
    exit 0
fi

# ---------- Get the target image while the current version keeps running ----------

OLD_ID="$(container_image_id "${CONTAINER}")"

if is_build_mode; then
    if ! ASPIA_VERSION="${TARGET}" ${COMPOSE} build --pull "${SERVICE}" >>"${LOG_FILE}" 2>&1; then
        fail "build of ${TARGET} failed, staying on ${CURRENT} (details in ${LOG_FILE})"
    fi
else
    if ! ASPIA_VERSION="${TARGET}" ${COMPOSE} pull --quiet "${SERVICE}" >>"${LOG_FILE}" 2>&1; then
        if [[ "${TARGET}" != "${CURRENT}" ]]; then
            log "Image ${TARGET_IMAGE} is not published yet, staying on ${CURRENT}"
        else
            log "WARNING: unable to pull ${TARGET_IMAGE}"
        fi
        self_update
        exit 0
    fi
fi

NEW_ID="$(image_id "${TARGET_IMAGE}")"
[[ -n "${NEW_ID}" ]] || fail "image ${TARGET_IMAGE} not found after pull/build"

if [[ "${TARGET}" == "${CURRENT}" && "${NEW_ID}" == "${OLD_ID}" ]]; then
    log "Aspia ${CURRENT} is up to date"
    self_update
    exit 0
fi

if [[ "${TARGET}" == "${CURRENT}" ]]; then
    log "Updating the image of Aspia ${CURRENT} (rebuilt image)"
else
    log "Updating Aspia ${CURRENT} -> ${TARGET}"
fi

# Keep the image of the running version for a rollback, even if its tag gets reused.
ROLLBACK_IMAGE="${TARGET_IMAGE%:*}:rollback"
[[ -n "${OLD_ID}" ]] && docker tag "${OLD_ID}" "${ROLLBACK_IMAGE}"

# ---------- Backup ----------

log "Stopping ${CURRENT}"
${COMPOSE} stop "${SERVICE}" >>"${LOG_FILE}" 2>&1

mkdir -p "${BACKUP_DIR}"
BACKUP="${BACKUP_DIR}/data_${CURRENT}_$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
if ! tar -czf "${BACKUP}" data/config data/database; then
    ${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1
    fail "backup failed, ${CURRENT} started again"
fi
log "Backup: ${BACKUP}"

ls -1t "${BACKUP_DIR}"/data_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f

# ---------- Start the new version ----------

set_version "${TARGET}"
${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1

if wait_healthy "${HEALTH_TIMEOUT}"; then
    log "Aspia ${TARGET} is running and healthy"
else
    log "ERROR: Aspia ${TARGET} is not healthy after ${HEALTH_TIMEOUT}s, rolling back to ${CURRENT}"
    docker logs --tail 30 "${CONTAINER}" >>"${LOG_FILE}" 2>&1
    ${COMPOSE} stop "${SERVICE}" >>"${LOG_FILE}" 2>&1

    rm -rf data/config data/database
    tar -xzf "${BACKUP}" || fail "unable to restore ${BACKUP}, restore it manually"

    set_version "${CURRENT}"
    [[ -n "${OLD_ID}" ]] && docker tag "${OLD_ID}" "$(service_image "${SERVICE}" "${CURRENT}")"
    ${COMPOSE} up -d --no-deps --pull never "${SERVICE}" >>"${LOG_FILE}" 2>&1

    if wait_healthy "${ROLLBACK_TIMEOUT}"; then
        fail "rolled back to ${CURRENT}"
    else
        fail "rolled back to ${CURRENT}, but it is not healthy either - check the server"
    fi
fi

# ---------- Cleanup: keep the running image and the rollback one ----------

REPO_NAME="${TARGET_IMAGE%:*}"
docker images "${REPO_NAME}" --format '{{.Tag}}' | grep -vxE "${TARGET//./\\.}|rollback|<none>" |
    while read -r tag; do
        docker rmi "${REPO_NAME}:${tag}" >>"${LOG_FILE}" 2>&1 && log "Removed image ${REPO_NAME}:${tag}"
    done
docker image prune -f >>"${LOG_FILE}" 2>&1
is_build_mode && docker builder prune -f >>"${LOG_FILE}" 2>&1

self_update
exit 0
