#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKUP_DIR:=/backups}"
: "${RETENTION_COUNT:=5}"
: "${SQLPACKAGE_EXTRA_ARGS:=}"

failures=()

fail() {
  echo "[backup] ERROR: $*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

build_connection_string() {
  local database="$1"
  local connection="$SQLSERVER_CONNECTION_STRING"

  if [[ "$connection" == *"{database}"* ]]; then
    connection="${connection//\{database\}/$database}"
  elif [[ "$connection" == *"{DATABASE}"* ]]; then
    connection="${connection//\{DATABASE\}/$database}"
  elif [[ "${#databases[@]}" -gt 1 ]]; then
    fail "SQLSERVER_CONNECTION_STRING must contain {database} when DATABASES has more than one database."
  fi

  printf '%s' "$connection"
}

cleanup_old_backups() {
  local database="$1"

  [[ "$RETENTION_COUNT" -gt 0 ]] || return 0

  mapfile -t old_files < <(
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "$database-*.bacpac" -printf '%T@ %p\n' \
      | sort -rn \
      | awk -v keep="$RETENTION_COUNT" 'NR > keep { $1=""; sub(/^ /, ""); print }'
  )

  if [[ "${#old_files[@]}" -gt 0 ]]; then
    echo "[backup] Removing ${#old_files[@]} old backup(s) for '$database'."
    rm -f -- "${old_files[@]}"
  fi
}

[[ -n "${SQLSERVER_CONNECTION_STRING:-}" ]] || fail "SQLSERVER_CONNECTION_STRING is required."
[[ -n "${DATABASES:-}" ]] || fail "DATABASES is required."
[[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || fail "RETENTION_COUNT must be a non-negative integer."

mkdir -p "$BACKUP_DIR"

IFS=',' read -r -a raw_databases <<< "$DATABASES"
databases=()

for raw_database in "${raw_databases[@]}"; do
  database="$(trim "$raw_database")"
  [[ -n "$database" ]] && databases+=("$database")
done

[[ "${#databases[@]}" -gt 0 ]] || fail "DATABASES does not contain any database names."

timestamp="$(date '+%Y-%m-%d-%H-%M-%S')"

echo "[backup] Starting backup run at $(date '+%Y-%m-%d %H:%M:%S %Z')."
echo "[backup] Databases: ${databases[*]}"

for database in "${databases[@]}"; do
  backup_file="$BACKUP_DIR/$database-$timestamp.bacpac"
  connection_string="$(build_connection_string "$database")"

  echo "[backup] Exporting '$database' to '$backup_file'."

  args=(
    "/Action:Export"
    "/SourceConnectionString:$connection_string"
    "/TargetFile:$backup_file"
  )

  if [[ -n "$SQLPACKAGE_EXTRA_ARGS" ]]; then
    read -r -a extra_args <<< "$SQLPACKAGE_EXTRA_ARGS"
    args+=("${extra_args[@]}")
  fi

  if sqlpackage "${args[@]}"; then
    if [[ -f "$backup_file" ]]; then
      size_bytes="$(stat -c '%s' "$backup_file")"
      size_mb="$(awk -v bytes="$size_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"
      echo "[backup] Completed '$database'. File size: ${size_mb} MB."
      cleanup_old_backups "$database"
    else
      echo "[backup] Export for '$database' finished but target file was not found." >&2
      failures+=("$database")
    fi
  else
    echo "[backup] Export failed for '$database'." >&2
    failures+=("$database")
  fi
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "[backup] Failed database(s): ${failures[*]}" >&2
  exit 1
fi

echo "[backup] Backup run completed successfully at $(date '+%Y-%m-%d %H:%M:%S %Z')."
