#!/usr/bin/env python3
import argparse
import os
import re
import sys
from dataclasses import dataclass

try:
    import yaml
except ImportError as exc:
    print(
        "[config] ERROR: PyYAML is required to read servers.yaml. "
        "Install python3-yaml in the container image.",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc


DEFAULT_CONFIG_PATH = "/etc/autosqlpackage/servers.yaml"
UNRESOLVED_BRACED_ENV = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
BARE_BRACED_PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
SAFE_NAME_CHARS = re.compile(r"[^A-Za-z0-9._-]+")


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class BackupTask:
    server_name: str
    database: str
    backup_dir: str
    retention_count: int
    connection_string: str
    backup_prefix: str


def fail(message: str) -> None:
    raise ConfigError(message)


def expand_env(value, label: str) -> str:
    if value is None:
        return ""

    expanded = os.path.expandvars(str(value))
    unresolved = sorted(set(UNRESOLVED_BRACED_ENV.findall(expanded)))
    if unresolved:
        names = ", ".join(unresolved)
        fail(f"{label} references undefined environment variable(s): {names}")

    return expanded


def parse_retention_count(value, label: str) -> int:
    text = str(value).strip()
    if not re.fullmatch(r"[0-9]+", text):
        fail(f"{label} must be a non-negative integer.")

    return int(text)


def parse_enabled(value, label: str) -> bool:
    if value is None:
        return True

    if isinstance(value, bool):
        return value

    text = str(value).strip().lower()
    if text in {"true", "1", "yes", "y", "on"}:
        return True
    if text in {"false", "0", "no", "n", "off"}:
        return False

    fail(f"{label} must be true or false.")


def sanitize_name(value: str, fallback: str) -> str:
    safe = SAFE_NAME_CHARS.sub("_", value.strip())
    safe = safe.strip("._-")
    return safe or fallback


def build_connection_string(template: str, database: str, database_count: int, label: str) -> str:
    if "{database}" in template:
        connection = template.replace("{database}", database)
    elif "{DATABASE}" in template:
        connection = template.replace("{DATABASE}", database)
    elif database_count > 1:
        fail(f"{label} must contain {{database}} when more than one database is configured.")
    else:
        connection = template

    unresolved = sorted(
        {
            name
            for name in BARE_BRACED_PLACEHOLDER.findall(connection)
            if name not in {"database", "DATABASE"}
        }
    )
    if unresolved:
        examples = ", ".join(f"{{{name}}}" for name in unresolved)
        fail(f"{label} contains unresolved placeholder(s): {examples}. Use ${{VAR_NAME}} for environment variables.")

    return connection


def load_yaml_tasks(config_path: str) -> list[BackupTask]:
    if not os.path.isfile(config_path):
        fail(f"YAML config file '{config_path}' was not found.")

    with open(config_path, "r", encoding="utf-8") as config_file:
        data = yaml.safe_load(config_file) or {}

    if not isinstance(data, dict):
        fail(f"{config_path} must contain a YAML object at the top level.")

    defaults = data.get("defaults") or {}
    if not isinstance(defaults, dict):
        fail("defaults must be a YAML object when provided.")

    servers = data.get("servers")
    if not isinstance(servers, list):
        fail("servers must be a YAML list.")

    default_backup_dir = expand_env(
        defaults.get("backup_dir", os.environ.get("BACKUP_DIR", "/backups")),
        "defaults.backup_dir",
    )
    default_retention_count = parse_retention_count(
        defaults.get("retention_count", os.environ.get("RETENTION_COUNT", "5")),
        "defaults.retention_count",
    )

    tasks: list[BackupTask] = []

    for index, server in enumerate(servers, start=1):
        server_label = f"servers[{index}]"
        if not isinstance(server, dict):
            fail(f"{server_label} must be a YAML object.")

        if not parse_enabled(server.get("enabled", True), f"{server_label}.enabled"):
            continue

        server_name = expand_env(server.get("name", f"server-{index}"), f"{server_label}.name").strip()
        if not server_name:
            fail(f"{server_label}.name must not be empty.")

        connection_template = expand_env(server.get("connection_string"), f"{server_label}.connection_string")
        if not connection_template:
            fail(f"{server_label}.connection_string is required.")

        databases = server.get("databases")
        if not isinstance(databases, list):
            fail(f"{server_label}.databases must be a YAML list.")

        database_names = []
        for database_index, database in enumerate(databases, start=1):
            database_name = expand_env(database, f"{server_label}.databases[{database_index}]").strip()
            if not database_name:
                fail(f"{server_label}.databases[{database_index}] must not be empty.")
            database_names.append(database_name)

        if not database_names:
            fail(f"{server_label}.databases must contain at least one database.")

        backup_dir = expand_env(server.get("backup_dir", default_backup_dir), f"{server_label}.backup_dir").strip()
        if not backup_dir:
            fail(f"{server_label}.backup_dir must not be empty.")

        retention_count = parse_retention_count(
            server.get("retention_count", default_retention_count),
            f"{server_label}.retention_count",
        )

        safe_server_name = sanitize_name(server_name, f"server-{index}")

        for database_name in database_names:
            safe_database = sanitize_name(database_name, "database")
            connection_string = build_connection_string(
                connection_template,
                database_name,
                len(database_names),
                f"{server_label}.connection_string",
            )
            tasks.append(
                BackupTask(
                    server_name=server_name,
                    database=database_name,
                    backup_dir=backup_dir,
                    retention_count=retention_count,
                    connection_string=connection_string,
                    backup_prefix=f"{safe_server_name}-{safe_database}",
                )
            )

    if not tasks:
        fail("servers.yaml does not define any enabled database backups.")

    return tasks


def load_legacy_tasks() -> list[BackupTask]:
    connection_template = os.environ.get("SQLSERVER_CONNECTION_STRING", "")
    databases_value = os.environ.get("DATABASES", "")

    if not connection_template or not databases_value:
        config_path = os.environ.get("SERVERS_CONFIG", DEFAULT_CONFIG_PATH)
        fail(
            f"Provide '{config_path}' or set the legacy SQLSERVER_CONNECTION_STRING "
            "and DATABASES environment variables."
        )

    database_names = [database.strip() for database in databases_value.split(",") if database.strip()]
    if not database_names:
        fail("DATABASES does not contain any database names.")

    backup_dir = os.environ.get("BACKUP_DIR", "/backups")
    retention_count = parse_retention_count(os.environ.get("RETENTION_COUNT", "5"), "RETENTION_COUNT")
    configured_server_name = os.environ.get("SERVER_NAME")
    server_name = configured_server_name or "default"
    safe_server_name = sanitize_name(server_name, "default")

    tasks = []
    for database_name in database_names:
        safe_database = sanitize_name(database_name, "database")
        backup_prefix = f"{safe_server_name}-{safe_database}" if configured_server_name else safe_database
        connection_string = build_connection_string(
            connection_template,
            database_name,
            len(database_names),
            "SQLSERVER_CONNECTION_STRING",
        )
        tasks.append(
            BackupTask(
                server_name=server_name,
                database=database_name,
                backup_dir=backup_dir,
                retention_count=retention_count,
                connection_string=connection_string,
                backup_prefix=backup_prefix,
            )
        )

    return tasks


def load_tasks() -> tuple[str, list[BackupTask]]:
    config_path = os.environ.get("SERVERS_CONFIG", DEFAULT_CONFIG_PATH)
    if config_path and os.path.exists(config_path):
        return config_path, load_yaml_tasks(config_path)

    return "legacy environment variables", load_legacy_tasks()


def write_nul(tasks: list[BackupTask]) -> None:
    fields = (
        "server_name",
        "database",
        "backup_dir",
        "retention_count",
        "connection_string",
        "backup_prefix",
    )

    for task in tasks:
        for field in fields:
            value = getattr(task, field)
            sys.stdout.buffer.write(str(value).encode("utf-8"))
            sys.stdout.buffer.write(b"\0")


def write_summary(source: str, tasks: list[BackupTask]) -> None:
    servers = sorted({task.server_name for task in tasks})
    print(f"[config] Loaded {len(tasks)} backup task(s) from {source}.")
    print(f"[config] Enabled server(s): {', '.join(servers)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Read AutoSQLPackage backup configuration.")
    parser.add_argument("--format", choices=["nul", "summary"], default="summary")
    parser.add_argument("--validate", action="store_true", help="Validate configuration and print a summary.")
    args = parser.parse_args()

    try:
        source, tasks = load_tasks()
    except ConfigError as exc:
        print(f"[config] ERROR: {exc}", file=sys.stderr)
        return 1

    if args.validate or args.format == "summary":
        write_summary(source, tasks)
    elif args.format == "nul":
        write_nul(tasks)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
