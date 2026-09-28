#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() {
  echo "[entrypoint] ERROR: $*" >&2
  exit 1
}

configure_timezone() {
  if [[ -f "/usr/share/zoneinfo/$TZ" ]]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
  else
    echo "[entrypoint] WARN: Unknown TZ '$TZ'; falling back to UTC." >&2
    TZ=UTC
    ln -snf /usr/share/zoneinfo/UTC /etc/localtime
    echo UTC > /etc/timezone
  fi

  export TZ
}

install_crontab() {
  local cron_dir=/var/spool/cron/crontabs
  local cron_file="$cron_dir/root"

  mkdir -p "$cron_dir"

  {
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "$CRON_EXPRESSION source /etc/autosqlpackage/env && /usr/local/bin/backup.sh >> /proc/1/fd/1 2>> /proc/1/fd/2"
  } > "$cron_file"

  chmod 0600 "$cron_file"
}

run_startup_backup_if_requested() {
  local normalized
  normalized="$(echo "$RUN_ON_STARTUP" | tr '[:upper:]' '[:lower:]')"

  case "$normalized" in
    true|1|yes|y)
      echo "[entrypoint] RUN_ON_STARTUP=true; running an immediate backup."
      if ! /usr/local/bin/backup.sh; then
        echo "[entrypoint] WARN: Startup backup failed; continuing to scheduled cron runs." >&2
      fi
      ;;
    false|0|no|n|"")
      ;;
    *)
      fail "RUN_ON_STARTUP must be true or false."
      ;;
  esac
}

config_env=/etc/autosqlpackage/env
if ! /usr/local/bin/autosqlpackage-config --format shell > "$config_env"; then
  fail "Could not load config.yaml."
fi
chmod 0600 "$config_env"
source "$config_env"

configure_timezone
printf 'export TZ=%q\n' "$TZ" >> "$config_env"
mkdir -p "$BACKUP_DIR"
install_crontab

echo "[entrypoint] AutoSQLPackage is scheduled with cron '$CRON_EXPRESSION' in timezone '$TZ'."
echo "[entrypoint] Backups will be written to '$BACKUP_DIR'."
echo "[entrypoint] Backup config: '/etc/autosqlpackage/config.yaml'."

run_startup_backup_if_requested

exec busybox crond -f -l 8 -L /proc/1/fd/1 -c /var/spool/cron/crontabs
