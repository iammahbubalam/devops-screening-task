#!/usr/bin/env bash
#
# system_health.sh - record CPU, memory and disk usage of this Linux host.
#
# Each run appends one timestamped line to LOG_FILE and prints the same line.
# When disk usage of DISK_PATH is above DISK_THRESHOLD percent it also prints
# "[WARNING] Disk space high!" to stderr.
#
# Exit status: 0 on success (also when the warning fires), 1 on any error.
# Requires: Linux (/proc), bash 4+, awk, df.

set -euo pipefail

# Fixed number and date formats, whatever the caller's locale is.
export LC_ALL=C

readonly LOG_FILE="${LOG_FILE:-./health_log.txt}"
readonly DISK_THRESHOLD="${DISK_THRESHOLD:-80}"
readonly DISK_PATH="${DISK_PATH:-/}"
readonly CPU_SAMPLE_SECONDS=1

usage() {
  cat <<EOF
Usage: ${0##*/} [-h|--help]

Appends CPU, memory and disk usage to a log file and warns when disk usage
is above the threshold.

Environment variables:
  LOG_FILE        file to append to           (default: ./health_log.txt)
  DISK_THRESHOLD  disk warning level, percent (default: 80)
  DISK_PATH       filesystem to check         (default: /)

Example:
  LOG_FILE=/var/log/system_health.log DISK_THRESHOLD=90 ${0##*/}
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_config() {
  # No leading zero allowed: bash would read "080" as an octal number.
  if [[ ! "$DISK_THRESHOLD" =~ ^[1-9][0-9]*$ ]] || ((DISK_THRESHOLD > 100)); then
    die "DISK_THRESHOLD must be a whole number from 1 to 100, got '$DISK_THRESHOLD'"
  fi
  if [[ ! -r /proc/stat || ! -r /proc/meminfo ]]; then
    die "cannot read /proc/stat and /proc/meminfo; this script needs Linux"
  fi
  if [[ ! -e "$DISK_PATH" ]]; then
    die "DISK_PATH '$DISK_PATH' does not exist"
  fi
}

# Prints "<idle> <total>" CPU time (in clock ticks) since boot, from the
# aggregate "cpu" line of /proc/stat. idle = idle + iowait. total = fields
# 2-9 (user .. steal); guest time is left out because the kernel already
# counts it inside user.
read_cpu_times() {
  awk '/^cpu / { print $5 + $6, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9; exit }' /proc/stat
}

# CPU usage in percent over CPU_SAMPLE_SECONDS. /proc/stat only holds totals
# since boot, so current usage is the difference between two readings.
get_cpu_usage() {
  local idle1 total1 idle2 total2
  read -r idle1 total1 < <(read_cpu_times)
  sleep "$CPU_SAMPLE_SECONDS"
  read -r idle2 total2 < <(read_cpu_times)

  awk -v idle="$((idle2 - idle1))" -v total="$((total2 - total1))" \
    'BEGIN { printf "%.1f", (total > 0 ? (1 - idle / total) * 100 : 0) }'
}

# Memory in use, in percent. MemAvailable is the kernel's estimate of memory
# that new programs can get, so reclaimable page cache does not count as used.
get_memory_usage() {
  awk '/^MemTotal:/     { total = $2 }
       /^MemAvailable:/ { available = $2 }
       END { if (total > 0) printf "%.1f", (total - available) / total * 100 }' /proc/meminfo
}

# Disk usage of DISK_PATH as a whole percent. -P (POSIX format) keeps each
# filesystem on a single line even when the device name is long.
get_disk_usage() {
  df -P -- "$DISK_PATH" | awk 'NR == 2 { sub(/%$/, "", $5); print $5 }'
}

main() {
  case "${1:-}" in
    "") ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  validate_config

  local cpu mem disk status="OK" entry
  cpu="$(get_cpu_usage)"
  mem="$(get_memory_usage)"
  disk="$(get_disk_usage)"
  [[ -n "$cpu" && -n "$mem" && "$disk" =~ ^[0-9]+$ ]] ||
    die "could not read system metrics (cpu='$cpu' mem='$mem' disk='$disk')"

  if ((disk > DISK_THRESHOLD)); then
    status="WARNING"
  fi

  # One line per run in key=value form, so grep, awk or a log shipper can
  # parse it. The host name matters once logs from many servers are collected.
  entry="$(date -Iseconds) host=${HOSTNAME:-$(uname -n)} cpu=${cpu}% mem=${mem}% disk=${disk}% status=${status}"

  printf '%s\n' "$entry" >>"$LOG_FILE" || die "cannot write to '$LOG_FILE'"
  printf '%s\n' "$entry"

  if [[ "$status" == "WARNING" ]]; then
    printf '[WARNING] Disk space high! %s is %s%% full (threshold %s%%)\n' \
      "$DISK_PATH" "$disk" "$DISK_THRESHOLD" >&2
  fi
}

main "$@"
