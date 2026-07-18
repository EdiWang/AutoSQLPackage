FROM mcr.microsoft.com/dotnet/runtime-deps:10.0 AS sqlpackage

ARG SQLPACKAGE_URL=https://download.microsoft.com/download/18a5e51e-8332-4cbe-bb50-6d3a50c704c5/sqlpackage-linux-x64-en-170.4.83.3.zip
ARG SQLPACKAGE_SHA256=E81EDE2429F3A15D9E752845C8928569C7706B3A911FAD2D1717C0F03E0FC7C3

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/sqlpackage \
    && curl -fkSL "$SQLPACKAGE_URL" -o /tmp/sqlpackage.zip \
    && echo "$SQLPACKAGE_SHA256  /tmp/sqlpackage.zip" | sha256sum -c - \
    && unzip -q /tmp/sqlpackage.zip -d /opt/sqlpackage \
    && chmod +x /opt/sqlpackage/sqlpackage \
    && rm /tmp/sqlpackage.zip

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV BACKUP_DIR=/backups \
    CRON_EXPRESSION="0 5 * * 4" \
    RETENTION_COUNT=5 \
    RUN_ON_STARTUP=false \
    SERVERS_CONFIG=/etc/autosqlpackage/servers.yaml \
    SQLPACKAGE_EXTRA_ARGS="" \
    TZ=UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        busybox-static \
        python3 \
        python3-yaml \
    && rm -rf /var/lib/apt/lists/*

COPY --from=sqlpackage /opt/sqlpackage /opt/sqlpackage

RUN ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/backup.sh /usr/local/bin/backup.sh
COPY scripts/config_tasks.py /usr/local/bin/autosqlpackage-config

RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh /usr/local/bin/autosqlpackage-config \
    && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh /usr/local/bin/autosqlpackage-config \
    && mkdir -p /backups /etc/autosqlpackage

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
