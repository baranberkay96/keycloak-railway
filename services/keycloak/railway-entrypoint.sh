#!/bin/bash
# Entrypoint for Keycloak on Railway.
#
# 1. Sizes the JVM from the container's cgroup limits. Keycloak's kc.sh default
#    (-XX:MaxRAMPercentage=70, InitialRAMPercentage=50) takes a share of
#    whatever memory the JVM sees; on Railway that can be the plan maximum, so
#    the heap would grow far beyond what an identity server needs. The JVM also
#    sizes its GC and HTTP thread pools from the visible CPU count.
# 2. Waits for Postgres, so a cold start of the whole project does not
#    crash-loop while the database is still being created.
# 3. With KC_CACHE=ispn (several replicas), binds the JGroups cluster transport
#    to the replica's private IPv6 address on railnet0.
# Finally it execs kc.sh, which runs the JVM and forwards SIGTERM to it.
#
# Overrides: JVM_HEAP_MAX_MB, JVM_HEAP_PERCENT, JVM_MAX_CPUS, DB_WAIT_SECONDS.
# Setting JAVA_OPTS or JAVA_OPTS_KC_HEAP yourself disables step 1.

set -u

readonly KC_SH=/opt/keycloak/bin/kc.sh
readonly DEFAULT_HEAP_MAX_MB=1024
readonly DEFAULT_HEAP_PERCENT=70
readonly MAX_HEAP_PERCENT=90
# Metaspace, code cache, thread stacks and network buffers. Keycloak's sizing
# guide measures about 300 MB of non-heap memory; keep some margin on top.
readonly NON_HEAP_RESERVE_MB=384
readonly MIN_HEAP_MB=256
readonly MIN_INITIAL_HEAP_MB=64
readonly DEFAULT_MAX_CPUS=4
readonly DEFAULT_DB_WAIT_SECONDS=600
readonly DB_PROBE_TIMEOUT_SECONDS=5
readonly DB_RETRY_SECONDS=5
# A cgroup memory limit of 1 TiB or more means "no real limit".
readonly UNLIMITED_BYTES=1099511627776
readonly CLUSTER_INTERFACE=railnet0

log() {
  printf '[railway-entrypoint] %s\n' "$*" >&2
}

# read_uint NAME VALUE DEFAULT MIN -> VALUE if it is an integer >= MIN, else DEFAULT.
read_uint() {
  local name="$1" value="$2" fallback="$3" min="$4"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$fallback"
  elif [[ "$value" =~ ^[0-9]{1,9}$ ]] && (( 10#$value >= min )); then
    printf '%s\n' "$(( 10#$value ))"
  else
    log "ignoring $name='$value' (expected an integer >= $min); using $fallback"
    printf '%s\n' "$fallback"
  fi
}

# Memory limit of this container in MiB; prints nothing when there is none.
cgroup_memory_mb() {
  local raw=""
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    read -r raw < /sys/fs/cgroup/memory.max
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    read -r raw < /sys/fs/cgroup/memory/memory.limit_in_bytes
  fi
  [[ "$raw" =~ ^[0-9]{1,19}$ ]] || return 0
  (( raw > 0 && raw < UNLIMITED_BYTES )) || return 0
  printf '%s\n' "$(( raw / 1048576 ))"
}

# CPU quota of this container, rounded up; prints nothing when there is none.
cgroup_cpus() {
  local quota="" period=""
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    read -r quota < /sys/fs/cgroup/cpu/cpu.cfs_quota_us
    read -r period < /sys/fs/cgroup/cpu/cpu.cfs_period_us
  fi
  [[ "$quota" =~ ^[0-9]{1,12}$ && "$period" =~ ^[0-9]{1,12}$ ]] || return 0
  (( quota > 0 && period > 0 )) || return 0
  printf '%s\n' "$(( (quota + period - 1) / period ))"
}

visible_cpus() {
  local cpus
  cpus="$(cgroup_cpus)"
  if [[ -z "$cpus" ]]; then
    cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  fi
  [[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus > 0 )) || cpus=1
  printf '%s\n' "$cpus"
}

configure_jvm() {
  if [[ -n "${JAVA_OPTS:-}" || -n "${JAVA_OPTS_KC_HEAP:-}" ]]; then
    log "JAVA_OPTS or JAVA_OPTS_KC_HEAP is set; automatic JVM sizing skipped"
    return 0
  fi

  local heap_cap percent limit_mb heap initial cpu_cap cpus
  heap_cap="$(read_uint JVM_HEAP_MAX_MB "${JVM_HEAP_MAX_MB:-}" "$DEFAULT_HEAP_MAX_MB" "$MIN_HEAP_MB")"
  percent="$(read_uint JVM_HEAP_PERCENT "${JVM_HEAP_PERCENT:-}" "$DEFAULT_HEAP_PERCENT" 10)"
  (( percent > MAX_HEAP_PERCENT )) && percent=$MAX_HEAP_PERCENT

  heap=$heap_cap
  limit_mb="$(cgroup_memory_mb)"
  if [[ -n "$limit_mb" ]]; then
    local by_percent=$(( limit_mb * percent / 100 ))
    local by_reserve=$(( limit_mb - NON_HEAP_RESERVE_MB ))
    (( by_percent < heap )) && heap=$by_percent
    (( by_reserve < heap )) && heap=$by_reserve
  fi
  (( heap < MIN_HEAP_MB )) && heap=$MIN_HEAP_MB
  initial=$(( heap / 4 ))
  (( initial < MIN_INITIAL_HEAP_MB )) && initial=$MIN_INITIAL_HEAP_MB

  cpu_cap="$(read_uint JVM_MAX_CPUS "${JVM_MAX_CPUS:-}" "$DEFAULT_MAX_CPUS" 1)"
  cpus="$(visible_cpus)"
  (( cpus > cpu_cap )) && cpus=$cpu_cap

  # kc.sh appends JAVA_OPTS_KC_HEAP to its default JAVA_OPTS (G1, ExitOnOutOfMemoryError, ...).
  # The free-ratio and periodic-GC flags let G1 hand unused heap back to the OS when idle.
  export JAVA_OPTS_KC_HEAP="-Xms${initial}m -Xmx${heap}m -XX:MinHeapFreeRatio=20 -XX:MaxHeapFreeRatio=40 -XX:G1PeriodicGCInterval=300000 -XX:ActiveProcessorCount=${cpus}"
  # Fewer glibc malloc arenas keep native memory (and the bill) lower on many-core hosts.
  export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
  log "memory limit: ${limit_mb:-none} MB -> heap ${initial}-${heap} MB; JVM CPUs: ${cpus}"
}

wait_for_database() {
  local host="${KC_DB_URL_HOST:-}" port="${KC_DB_URL_PORT:-}"
  local url_pattern='^jdbc:postgresql://(\[[^]]+\]|[^/:?,]+)(:([0-9]+))?'
  if [[ -z "$host" && "${KC_DB_URL:-}" =~ $url_pattern ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]}"
  fi
  host="${host#\[}"
  host="${host%\]}"
  if [[ -z "$host" ]]; then
    log "no database host found in KC_DB_URL_HOST or KC_DB_URL; not waiting"
    return 0
  fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=5432

  local limit started
  limit="$(read_uint DB_WAIT_SECONDS "${DB_WAIT_SECONDS:-}" "$DEFAULT_DB_WAIT_SECONDS" 0)"
  (( limit == 0 )) && return 0

  started=$SECONDS
  log "waiting up to ${limit}s for the database at ${host}:${port}"
  until timeout "$DB_PROBE_TIMEOUT_SECONDS" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null; do
    if (( SECONDS - started >= limit )); then
      log "database still unreachable after ${limit}s; starting Keycloak anyway (it retries via the restart policy)"
      return 0
    fi
    sleep "$DB_RETRY_SECONDS"
  done
  log "database reachable after $(( SECONDS - started ))s"
}

configure_cluster() {
  # Production default for KC_CACHE is ispn; the template sets local (one replica).
  [[ "${KC_CACHE:-ispn}" == "ispn" ]] || return 0
  [[ -z "${KC_CACHE_EMBEDDED_NETWORK_BIND_ADDRESS:-}" ]] || return 0
  [[ -r /proc/net/if_inet6 ]] || return 0

  # /proc/net/if_inet6: address(32 hex) ifindex prefixlen scope flags name; scope 00 = global/ULA.
  local hex _index _prefix scope _flags name addr
  while read -r hex _index _prefix scope _flags name; do
    if [[ "$name" == "$CLUSTER_INTERFACE" && "$scope" == "00" && "$hex" =~ ^[0-9a-fA-F]{32}$ ]]; then
      addr="${hex:0:4}:${hex:4:4}:${hex:8:4}:${hex:12:4}:${hex:16:4}:${hex:20:4}:${hex:24:4}:${hex:28:4}"
      export KC_CACHE_EMBEDDED_NETWORK_BIND_ADDRESS="$addr"
      log "clustering: JGroups binds to ${addr} on ${CLUSTER_INTERFACE}"
      return 0
    fi
  done < /proc/net/if_inet6
  log "clustering: no global IPv6 address on ${CLUSTER_INTERFACE}; JGroups picks its default address"
}

main() {
  configure_jvm
  wait_for_database
  configure_cluster
  exec "$KC_SH" "$@"
}

main "$@"
