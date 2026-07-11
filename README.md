# AutoSQLPackage

AutoSQLPackage is a small Dockerized backup runner for exporting SQL Server or Azure SQL databases to `.bacpac` files with `sqlpackage`.

It uses a Bash backup script and cron inside the container. Backup targets are supplied through a YAML file.

## Configuration

Copy `.env.example` to `.env`, then edit `servers.yaml`.

```env
SERVERS_CONFIG=/etc/autosqlpackage/servers.yaml
SERVERS_CONFIG_HOST=./servers.yaml
CRON_EXPRESSION=0 5 * * 4
BACKUP_DIR=/backups
HOST_BACKUP_DIR=./backups
RETENTION_COUNT=5
RUN_ON_STARTUP=false
TZ=UTC
SQLPACKAGE_EXTRA_ARGS=
```

`servers.yaml` describes each server connection string and the databases to export:

```yaml
defaults:
  backup_dir: /backups
  retention_count: 5

servers:
  - name: prod-east
    enabled: true
    connection_string: "Server=tcp:prod-east.database.windows.net,1433;Database={database};User ID=${PROD_EAST_SQL_USER};Password=${PROD_EAST_SQL_PASSWORD};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    databases:
      - RMSMain
      - RMSForms

  - name: internal-reporting
    enabled: true
    retention_count: 10
    connection_string: "Server=tcp:10.0.1.25,1433;Database={database};User ID=${REPORTING_SQL_USER};Password=${REPORTING_SQL_PASSWORD};Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
    databases:
      - Reporting
      - AuditLog
```

`connection_string` should normally contain `{database}`. The backup script replaces it with each database name. Values like `${PROD_EAST_SQL_PASSWORD}` are expanded from container environment variables, so keep secrets in `.env` instead of committing them to YAML.

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

By default, the newest 5 `.bacpac` files are retained per server/database pair. Change `defaults.retention_count` in `servers.yaml` to adjust that number, or set `retention_count` on one server to override it.

Backup files include the server name to avoid collisions when multiple servers contain databases with the same name:

```text
prod-east-RMSMain-2026-07-11-05-00-00.bacpac
internal-reporting-AuditLog-2026-07-11-05-00-00.bacpac
```

## Legacy Environment Variables

If `SERVERS_CONFIG` does not point to an existing file, the container still supports the legacy `SQLSERVER_CONNECTION_STRING` and `DATABASES` environment variables.

## Notes

`.bacpac` files contain schema and data. Treat the backup directory as sensitive storage.
