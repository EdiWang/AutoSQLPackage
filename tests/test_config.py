from pathlib import Path
import sys
from tempfile import TemporaryDirectory


root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "scripts"))
from config_tasks import ConfigError, load_config  # noqa: E402


sample = (root / "config.example.yaml").read_text(encoding="utf-8")
settings, tasks = load_config(str(root / "config.example.yaml"))
assert settings["CRON_EXPRESSION"] == "0 5 * * 4"
assert settings["BACKUP_DIR"] == "/backups"
assert len(tasks) == 7
assert "Database=RMSMain" in tasks[0].connection_string
assert tasks[-1].retention_count == 10

with TemporaryDirectory() as directory:
    path = Path(directory) / "config.yaml"
    for invalid in (
        sample.replace("Password=change-me", "Password=${SQL_PASSWORD}", 1),
        sample.replace("backup_dir: /backups", "backup_dir: /tmp", 1),
    ):
        path.write_text(invalid, encoding="utf-8")
        try:
            load_config(str(path))
        except ConfigError:
            pass
        else:
            raise AssertionError("Invalid configuration was accepted")

print("config check passed")
