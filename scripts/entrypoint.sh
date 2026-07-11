#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKUP_DIR:=/backups}"
: "${CRON_EXPRESSION:=0 5 * * 4}"
: "${RETENTION_COUNT:=5}"
: "${RUN_ON_STARTUP:=false}"
: "${SERVERS_CONFIG:=/etc/autosqlpackage/servers.yaml}"
: "${TZ:=UTC}"
: "${SQLPACKAGE_EXTRA_ARGS:=}"

fail() {
  echo "[entrypoint] ERROR: $*" >&2
  exit 1
}

validate_required_config() {
  read -r -a cron_parts <<< "$CRON_EXPRESSION"
  [[ "${#cron_parts[@]}" -eq 5 ]] || fail "CRON_EXPRESSION must use the standard 5-field format, for example: 0 5 * * 4"

  /usr/local/bin/backup.sh --validate-config
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
  while IFS= read -r name; do
    case "$name" in
      BASH_FUNC_*|PWD|SHLVL|_)
        continue
        ;;
    esac

    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -v "$name" ]]; then
      printf 'export %s=%q\n' "$name" "${!name}" >> "$env_file"
    fi
  done < <(compgen -e | sort)
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
echo "[entrypoint] Backup config: '$SERVERS_CONFIG'."

run_startup_backup_if_requested

exec busybox crond -f -l 8 -L /proc/1/fd/1 -c /var/spool/cron/crontabs
