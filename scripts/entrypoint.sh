#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKUP_DIR:=/backups}"
: "${CRON_EXPRESSION:=0 5 * * 4}"
: "${RETENTION_COUNT:=5}"
: "${RUN_ON_STARTUP:=false}"
: "${TZ:=UTC}"
: "${SQLPACKAGE_EXTRA_ARGS:=}"

fail() {
  echo "[entrypoint] ERROR: $*" >&2
  exit 1
}

validate_required_config() {
  [[ -n "${SQLSERVER_CONNECTION_STRING:-}" ]] || fail "SQLSERVER_CONNECTION_STRING is required."
  [[ -n "${DATABASES:-}" ]] || fail "DATABASES is required."

  read -r -a cron_parts <<< "$CRON_EXPRESSION"
  [[ "${#cron_parts[@]}" -eq 5 ]] || fail "CRON_EXPRESSION must use the standard 5-field format, for example: 0 5 * * 4"

  [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || fail "RETENTION_COUNT must be a non-negative integer."
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

write_environment_file() {
  local env_file=/etc/autosqlpackage/env
  : > "$env_file"

  local name
  for name in \
    BACKUP_DIR \
    CRON_EXPRESSION \
    DATABASES \
    RETENTION_COUNT \
    RUN_ON_STARTUP \
    SQLPACKAGE_EXTRA_ARGS \
    SQLSERVER_CONNECTION_STRING \
    TZ
  do
    if [[ -v "$name" ]]; then
      printf 'export %s=%q\n' "$name" "${!name}" >> "$env_file"
    fi
  done
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
      /usr/local/bin/backup.sh
      ;;
    false|0|no|n|"")
      ;;
    *)
      fail "RUN_ON_STARTUP must be true or false."
      ;;
  esac
}

validate_required_config
configure_timezone
mkdir -p "$BACKUP_DIR"
write_environment_file
install_crontab

echo "[entrypoint] AutoSQLPackage is scheduled with cron '$CRON_EXPRESSION' in timezone '$TZ'."
echo "[entrypoint] Backups will be written to '$BACKUP_DIR'."

run_startup_backup_if_requested

exec busybox crond -f -l 8 -L /proc/1/fd/1 -c /var/spool/cron/crontabs
