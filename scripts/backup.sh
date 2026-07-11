#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKUP_DIR:=/backups}"
: "${RETENTION_COUNT:=5}"
: "${SERVERS_CONFIG:=/etc/autosqlpackage/servers.yaml}"
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

run_config_tool() {
  if command -v autosqlpackage-config >/dev/null 2>&1; then
    autosqlpackage-config "$@"
  elif command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config_tasks.py" "$@"
  else
    python "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config_tasks.py" "$@"
  fi
}

cleanup_old_backups() {
  local backup_dir="$1"
  local backup_prefix="$2"
  local retention_count="$3"
  local label="$4"

  [[ "$retention_count" -gt 0 ]] || return 0

  mapfile -t old_files < <(
    find "$backup_dir" -maxdepth 1 -type f -name "$backup_prefix-*.bacpac" -printf '%T@ %p\n' \
      | sort -rn \
      | awk -v keep="$retention_count" 'NR > keep { $1=""; sub(/^ /, ""); print }'
  )

  if [[ "${#old_files[@]}" -gt 0 ]]; then
    echo "[backup] Removing ${#old_files[@]} old backup(s) for '$label'."
    rm -f -- "${old_files[@]}"
  fi
}

if [[ "${1:-}" == "--validate-config" ]]; then
  run_config_tool --validate
  exit 0
fi

tasks_file="$(mktemp)"
trap 'rm -f "$tasks_file"' EXIT

run_config_tool --format nul > "$tasks_file"

timestamp="$(date '+%Y-%m-%d-%H-%M-%S')"
task_count=0

echo "[backup] Starting backup run at $(date '+%Y-%m-%d %H:%M:%S %Z')."

while IFS= read -r -d '' server_name; do
  IFS= read -r -d '' database || fail "Backup task data is malformed."
  IFS= read -r -d '' backup_dir || fail "Backup task data is malformed."
  IFS= read -r -d '' retention_count || fail "Backup task data is malformed."
  IFS= read -r -d '' connection_string || fail "Backup task data is malformed."
  IFS= read -r -d '' backup_prefix || fail "Backup task data is malformed."

  [[ "$retention_count" =~ ^[0-9]+$ ]] || fail "retention_count for '$server_name/$database' must be a non-negative integer."

  mkdir -p "$backup_dir"

  task_count=$((task_count + 1))
  backup_file="$backup_dir/$backup_prefix-$timestamp.bacpac"
  label="$server_name/$database"

  echo "[backup] Exporting '$label' to '$backup_file'."

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
      echo "[backup] Completed '$label'. File size: ${size_mb} MB."
      cleanup_old_backups "$backup_dir" "$backup_prefix" "$retention_count" "$label"
    else
      echo "[backup] Export for '$label' finished but target file was not found." >&2
      failures+=("$label")
    fi
  else
    echo "[backup] Export failed for '$label'." >&2
    failures+=("$label")
  fi
done < "$tasks_file"

[[ "$task_count" -gt 0 ]] || fail "No backup tasks were loaded."

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "[backup] Failed database(s): ${failures[*]}" >&2
  exit 1
fi

echo "[backup] Backup run completed successfully at $(date '+%Y-%m-%d %H:%M:%S %Z')."
