ARG DEBIAN_TAG=stable-slim
FROM debian:${DEBIAN_TAG}

# Works with both BuildKit and the classic builder (Synology Container Manager).
ARG ASPIA_VERSION

LABEL org.opencontainers.image.title="Aspia Server" \
      org.opencontainers.image.description="Aspia Router + Relay in a single container" \
      org.opencontainers.image.version="${ASPIA_VERSION}" \
      org.opencontainers.image.source="https://github.com/dchapyshev/aspia" \
      org.opencontainers.image.licenses="GPL-3.0"

ENV ASPIA_VERSION=${ASPIA_VERSION} \
    LANG=C.UTF-8

# One layer: download the release packages and install them (apt resolves libdbus-1-3, the only
# dependency - Qt is linked statically). curl stays in the image for EXTERNAL_IP=auto.
# postinst runs "--install", which is a no-op while no configuration exists.
RUN set -e; \
    test -n "${ASPIA_VERSION}" || { echo "ASPIA_VERSION is not set" >&2; exit 1; }; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl jq tzdata; \
    mkdir /tmp/pkg; \
    for component in router relay; do \
        curl -fsSL -o "/tmp/pkg/aspia-${component}.deb" \
            "https://github.com/dchapyshev/aspia/releases/download/v${ASPIA_VERSION}/aspia-${component}-${ASPIA_VERSION}-x86_64.deb"; \
    done; \
    apt-get install -y --no-install-recommends /tmp/pkg/*.deb; \
    rm -rf /tmp/pkg /var/lib/apt/lists/*

COPY aspia_start aspia_health /usr/bin/
RUN chmod 755 /usr/bin/aspia_start /usr/bin/aspia_health

# Configuration and keys, database, logs. Keep them on volumes or bind mounts.
VOLUME ["/etc/aspia", "/var/lib/aspia", "/var/log/aspia"]

# Publish the ports unchanged (-p 8062:8062 ...): the relay announces its own port to the clients.
# 8060 hosts 2.x | 8061 hosts 3.x | 8062 clients | 8063 relay <-> router | 8065/udp STUN | 8070 relay peers
EXPOSE 8060 8061 8062 8063 8065/udp 8070

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 CMD ["/usr/bin/aspia_health"]

CMD ["/usr/bin/aspia_start"]
