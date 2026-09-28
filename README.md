# AutoSQLPackage

AutoSQLPackage exports SQL Server or Azure SQL databases to `.bacpac` files with `sqlpackage`. A container runs the backups on a cron schedule.

## Configuration

Copy `config.example.yaml` to `config.yaml`, then edit the schedule, servers, databases, and connection strings. Put the real user names and passwords directly in `config.yaml`.

```bash
cp config.example.yaml config.yaml
```

`config.yaml` is ignored by Git and excluded from the Docker build context. Keep it private and do not commit it. The container mounts it read-only at `/etc/autosqlpackage/config.yaml`.

```yaml
schedule: "0 5 * * 4"
timezone: Asia/Taipei
run_on_startup: false
sqlpackage_extra_args: ""
defaults:
  backup_dir: /backups
  retention_count: 5
servers:
  - name: prod-east
    connection_string: "Server=tcp:example.database.windows.net,1433;Database={database};User ID=sa;Password=change-me;Encrypt=True;TrustServerCertificate=False;"
    databases: [RMSMain, RMSForms]
```

The default schedule is every Thursday at 05:00 in the configured time zone. `connection_string` should contain `{database}` when the server has more than one database. Set `enabled: false` on a server to skip it. A server can override `defaults.retention_count`.

Backups are mounted at `./backups` on the host and `/backups` in the container. Keep `defaults.backup_dir` and any server `backup_dir` under `/backups` so the files persist on the host.

The old `.env` and `servers.yaml` configuration is no longer used. Move any real credentials and settings from them into `config.yaml` before upgrading.

## Run

Build and start:

```bash
docker compose up -d --build
```

After changing `config.yaml`, recreate the container so the schedule and time zone are reloaded:

```bash
docker compose up -d --force-recreate
```

View logs:

```bash
docker compose logs -f autosqlpackage
```

Set `run_on_startup: true` in `config.yaml` and recreate the container to run one immediate backup.

## Backup retention

The newest 5 `.bacpac` files are retained per server/database pair by default. Change `defaults.retention_count` or set `retention_count` on a server. Set it to `0` to keep all backups.

Backups are grouped by server:

```text
/backups/prod-east/RMSMain-2026-07-11-05-00-00.bacpac
/backups/internal-reporting/AuditLog-2026-07-11-05-00-00.bacpac
```

`.bacpac` files contain schema and data. Treat the backup directory as sensitive storage.
