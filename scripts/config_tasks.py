#!/usr/bin/env python3
import argparse
import os
import posixpath
import re
import shlex
import sys
from dataclasses import dataclass

try:
    import yaml
except ImportError as exc:
    print(
        "[config] ERROR: PyYAML is required to read config.yaml. "
        "Install python3-yaml in the container image.",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc


DEFAULT_CONFIG_PATH = "/etc/autosqlpackage/config.yaml"
ENV_PLACEHOLDER = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")
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


def config_text(value, label: str) -> str:
    if value is None:
        return ""

    text = str(value)
    if ENV_PLACEHOLDER.search(text):
        fail(f"{label} contains an environment placeholder; put its value directly in config.yaml.")

    return text


def backup_path(value, label: str) -> str:
    path = config_text(value, label).strip()
    if not posixpath.isabs(path) or posixpath.commonpath(("/backups", posixpath.normpath(path))) != "/backups":
        fail(f"{label} must be under /backups so files persist on the host.")
    return path


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
        fail(f"{label} contains unresolved placeholder(s): {examples}.")

    return connection


def load_config(config_path: str) -> tuple[dict[str, str], list[BackupTask]]:
    if not os.path.isfile(config_path):
        fail(f"Config file '{config_path}' was not found.")

    with open(config_path, "r", encoding="utf-8") as config_file:
        data = yaml.safe_load(config_file) or {}

    if not isinstance(data, dict):
        fail(f"{config_path} must contain a YAML object at the top level.")

    settings = {
        "CRON_EXPRESSION": config_text(data.get("schedule", "0 5 * * 4"), "schedule").strip(),
        "TZ": config_text(data.get("timezone", "UTC"), "timezone").strip(),
        "RUN_ON_STARTUP": str(parse_enabled(data.get("run_on_startup", False), "run_on_startup")).lower(),
        "SQLPACKAGE_EXTRA_ARGS": config_text(data.get("sqlpackage_extra_args", ""), "sqlpackage_extra_args"),
    }
    if len(settings["CRON_EXPRESSION"].split()) != 5 or any(
        character in settings["CRON_EXPRESSION"] for character in "\r\n"
    ):
        fail("schedule must use a 5-field cron expression, for example: 0 5 * * 4.")
    if not settings["TZ"]:
        fail("timezone must not be empty.")

    defaults = data.get("defaults") or {}
    if not isinstance(defaults, dict):
        fail("defaults must be a YAML object when provided.")

    servers = data.get("servers")
    if not isinstance(servers, list):
        fail("servers must be a YAML list.")

    default_backup_dir = backup_path(
        defaults.get("backup_dir", "/backups"),
        "defaults.backup_dir",
    )
    default_retention_count = parse_retention_count(
        defaults.get("retention_count", 5),
        "defaults.retention_count",
    )
    settings["BACKUP_DIR"] = default_backup_dir

    tasks: list[BackupTask] = []

    for index, server in enumerate(servers, start=1):
        server_label = f"servers[{index}]"
        if not isinstance(server, dict):
            fail(f"{server_label} must be a YAML object.")

        if not parse_enabled(server.get("enabled", True), f"{server_label}.enabled"):
            continue

        server_name = config_text(server.get("name", f"server-{index}"), f"{server_label}.name").strip()
        if not server_name:
            fail(f"{server_label}.name must not be empty.")

        connection_template = config_text(server.get("connection_string"), f"{server_label}.connection_string")
        if not connection_template:
            fail(f"{server_label}.connection_string is required.")

        databases = server.get("databases")
        if not isinstance(databases, list):
            fail(f"{server_label}.databases must be a YAML list.")

        database_names = []
        for database_index, database in enumerate(databases, start=1):
            database_name = config_text(database, f"{server_label}.databases[{database_index}]").strip()
            if not database_name:
                fail(f"{server_label}.databases[{database_index}] must not be empty.")
            database_names.append(database_name)

        if not database_names:
            fail(f"{server_label}.databases must contain at least one database.")

        backup_dir = backup_path(server.get("backup_dir", default_backup_dir), f"{server_label}.backup_dir")

        retention_count = parse_retention_count(
            server.get("retention_count", default_retention_count),
            f"{server_label}.retention_count",
        )

        safe_server_name = sanitize_name(server_name, f"server-{index}")
        server_backup_dir = os.path.join(backup_dir, safe_server_name)

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
                    backup_dir=server_backup_dir,
                    retention_count=retention_count,
                    connection_string=connection_string,
                    backup_prefix=safe_database,
                )
            )

    if not tasks:
        fail("config.yaml does not define any enabled database backups.")

    return settings, tasks


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


def write_shell(settings: dict[str, str]) -> None:
    for name, value in settings.items():
        print(f"export {name}={shlex.quote(value)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Read AutoSQLPackage backup configuration.")
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="Path to config.yaml.")
    parser.add_argument("--format", choices=["nul", "summary", "shell"], default="summary")
    parser.add_argument("--validate", action="store_true", help="Validate configuration and print a summary.")
    args = parser.parse_args()

    try:
        settings, tasks = load_config(args.config)
    except ConfigError as exc:
        print(f"[config] ERROR: {exc}", file=sys.stderr)
        return 1

    if args.validate or args.format == "summary":
        write_summary(args.config, tasks)
    elif args.format == "nul":
        write_nul(tasks)
    elif args.format == "shell":
        write_shell(settings)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
