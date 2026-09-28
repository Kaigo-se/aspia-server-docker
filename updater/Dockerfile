FROM alpine:3

LABEL org.opencontainers.image.title="Aspia Server updater" \
      org.opencontainers.image.description="Keeps the Aspia Server container on the latest Aspia release" \
      org.opencontainers.image.licenses="GPL-3.0"

RUN apk add --no-cache bash coreutils curl findutils grep jq sed tar tzdata unzip \
        docker-cli docker-cli-buildx docker-cli-compose

COPY entrypoint.sh update.sh import-2x.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/update.sh /usr/local/bin/import-2x.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
