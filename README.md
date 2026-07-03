# AutoSQLPackage

AutoSQLPackage is a small Dockerized backup runner for exporting SQL Server or Azure SQL databases to `.bacpac` files with `sqlpackage`.

It uses a Bash backup script and cron inside the container. Configuration is supplied through Docker Compose environment variables.

## Configuration

Copy `.env.example` to `.env` and edit it:

```env
SQLSERVER_CONNECTION_STRING=Server=tcp:example.database.windows.net,1433;Database={database};User ID=sa;Password=change-me;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;
DATABASES=RMSMain,RMSForms
CRON_EXPRESSION=0 5 * * 4
BACKUP_DIR=/backups
HOST_BACKUP_DIR=./backups
RETENTION_COUNT=5
RUN_ON_STARTUP=false
TZ=UTC
SQLPACKAGE_EXTRA_ARGS=
```

`SQLSERVER_CONNECTION_STRING` should normally contain `{database}`. The backup script replaces it with each name from `DATABASES`.

The default schedule is every Thursday at 05:00 in the configured `TZ`. Set `TZ=Asia/Shanghai` or another IANA time zone if you want local-time scheduling and timestamps.

## Run

Build and start:

```bash
docker compose up -d --build
```

View logs:

```bash
docker compose logs -f autosqlpackage
```

Run one immediate backup by setting:

```env
RUN_ON_STARTUP=true
```

Then restart the service:

```bash
docker compose up -d
```

## Backup Retention

By default, the newest 5 `.bacpac` files are retained per database. Change `RETENTION_COUNT` to adjust that number.

## Notes

`.bacpac` files contain schema and data. Treat the backup directory as sensitive storage.
