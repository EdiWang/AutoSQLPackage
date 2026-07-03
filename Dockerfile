FROM mcr.microsoft.com/dotnet/sdk:10.0 AS sqlpackage

ARG SQLPACKAGE_VERSION=170.4.83

RUN dotnet tool install microsoft.sqlpackage \
    --tool-path /opt/sqlpackage \
    --version "$SQLPACKAGE_VERSION"

FROM mcr.microsoft.com/dotnet/runtime:10.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV BACKUP_DIR=/backups \
    CRON_EXPRESSION="0 5 * * 4" \
    RETENTION_COUNT=5 \
    RUN_ON_STARTUP=false \
    TZ=UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cron \
        tzdata \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=sqlpackage /opt/sqlpackage /opt/sqlpackage

RUN ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/backup.sh /usr/local/bin/backup.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh \
    && mkdir -p /backups /etc/autosqlpackage

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
