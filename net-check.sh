#!/usr/bin/env bash
#
# netcheck.sh — Interactive & CLI Linux Network Diagnostics Tool
# Features:
#   - Interactive TUI menu OR non-interactive CLI flags
#   - Interface & default gateway discovery + latency check
#   - External ICMP reachability & packet loss measurement
#   - Public IPv4/IPv6 detection with multiple fallbacks
#   - Multi-resolver DNS lookup + query latency benchmarking
#   - TCP port & HTTP/HTTPS endpoint health checks
#   - External config file support (~/.config/netcheck.conf or ./netcheck.conf)
#   - Optional report export to timestamped log file

set -o errexit
set -o nounset
set -o pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Default Configuration (overridden by netcheck.conf if present)
# -----------------------------------------------------------------------------
PING_TARGETS=("1.1.1.1" "9.9.9.9")
PING_COUNT=3
PING_TIMEOUT=2

DNS_DOMAIN="example.com"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")

TCP_TARGETS=("github.com:443" "google.com:443")
HTTP_TARGETS=("https://www.google.com" "https://cloudflare.com")

ENABLE_COLOR=1
SAVE_REPORT=0
REPORT_DIR="./reports"

# Runtime state
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
REPORT_BUFFER=""

# -----------------------------------------------------------------------------
# Terminal Colors & Output Helpers
# -----------------------------------------------------------------------------
setup_colors() {
  if [[ "$ENABLE_COLOR" -eq 1 && -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_DIM=$'\033[2m'
  else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_DIM=""
  fi
}

log_line() {
  local plain="$1"
  local formatted="$2"
  printf "%b\n" "$formatted"
  REPORT_BUFFER+="${plain}"$'\n'
}

section() {
  local title="$1"
  log_line "" ""
  log_line "=== ${title} ===" "${C_BOLD}${C_CYAN}=== ${title} ===${C_RESET}"
}

pass() {
  local msg="$1"
  PASS_COUNT=$((PASS_COUNT + 1))
  log_line "[PASS] ${msg}" "${C_GREEN}[PASS]${C_RESET} ${msg}"
}

warn() {
  local msg="$1"
  WARN_COUNT=$((WARN_COUNT + 1))
  log_line "[WARN] ${msg}" "${C_YELLOW}[WARN]${C_RESET} ${msg}"
}

fail() {
  local msg="$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log_line "[FAIL] ${msg}" "${C_RED}[FAIL]${C_RESET} ${msg}"
}

info() {
  local msg="$1"
  log_line "[INFO] ${msg}" "${C_BLUE}[INFO]${C_RESET} ${msg}"
}

# -----------------------------------------------------------------------------
# Cleanup & Signal Trap
# -----------------------------------------------------------------------------
cleanup() {
  printf "%b" "${C_RESET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Configuration Loader
# -----------------------------------------------------------------------------
load_config() {
  local cfg=""
  if [[ -f "${SCRIPT_DIR}/netcheck.conf" ]]; then
    cfg="${SCRIPT_DIR}/netcheck.conf"
  elif [[ -f "${HOME}/.config/netcheck.conf" ]]; then
    cfg="${HOME}/.config/netcheck.conf"
  fi

  if [[ -n "$cfg" ]]; then
    # shellcheck source=/dev/null
    source "$cfg"
  fi
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------
has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

now_ms() {
  if date +%s%3N >/dev/null 2>&1 && [[ "$(date +%s%3N)" =~ ^[0-9]+$ ]]; then
    date +%s%3N
  else
    # Fallback to seconds * 1000 if millisecond format unsupported
    printf "%s000" "$(date +%s)"
  fi
}

measure_ping() {
  local host="$1"
  local out avg loss
  if ! out=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" 2>/dev/null); then
    return 1
  fi

  loss=$(printf "%s\n" "$out" | awk -F',' '/packet loss/ { gsub(/[^0-9.]/, "", $3); print $3 }')
  avg=$(printf "%s\n" "$out" | awk -F'/' '/rtt|round-trip/ { print $5 }')

  printf "%s|%s" "${avg:-n/a}" "${loss:-100}"
  return 0
}

# -----------------------------------------------------------------------------
# Diagnostic Checks
# -----------------------------------------------------------------------------
check_interfaces_and_gateway() {
  section "1. Local Network & Default Gateway"

  if has_cmd ip; then
    local active_ifaces
    active_ifaces=$(ip -brief addr show up 2>/dev/null | awk '$1 != "lo" { printf "%s (%s)  ", $1, $3 }')
    if [[ -n "$active_ifaces" ]]; then
      pass "Active interfaces: ${active_ifaces}"
    else
      fail "No active non-loopback network interfaces found"
    fi

    local gateway gw_dev
    gateway=$(ip route 2>/dev/null | awk '/^default/ { print $3; exit }')
    gw_dev=$(ip route 2>/dev/null | awk '/^default/ { print $5; exit }')

    if [[ -n "$gateway" ]]; then
      info "Default gateway: ${gateway} via ${gw_dev:-unknown}"
      local stats avg loss
      if stats=$(measure_ping "$gateway"); then
        avg="${stats%%|*}"
        loss="${stats##*|}"
        pass "Gateway ${gateway} reachable (avg: ${avg} ms, loss: ${loss}%)"
      else
        fail "Default gateway ${gateway} is unreachable via ICMP"
      fi
    else
      fail "No default route configured"
    fi
  else
    warn "'ip' command not found (install iproute2); skipping interface check"
  fi
}

check_external_icmp() {
  section "2. External Internet Reachability (ICMP)"

  local target stats avg loss
  for target in "${PING_TARGETS[@]}"; do
    if stats=$(measure_ping "$target"); then
      avg="${stats%%|*}"
      loss="${stats##*|}"
      if [[ "$loss" != "0" && "$loss" != "0.0" ]]; then
        warn "Reachable ${target} with packet loss (avg: ${avg} ms, loss: ${loss}%)"
      else
        pass "Reachable ${target} (avg: ${avg} ms, loss: ${loss}%)"
      fi
    else
      fail "Cannot reach external host ${target}"
    fi
  done
}

check_public_ip() {
  section "3. Public IP & External Visibility"

  local pub_ip=""
  if has_cmd curl; then
    pub_ip=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null \
          || curl -4 -fsS --max-time 4 https://ifconfig.me/ip 2>/dev/null \
          || true)
  elif has_cmd wget; then
    pub_ip=$(wget -4 -qO- --timeout=4 https://api.ipify.org 2>/dev/null || true)
  elif has_cmd dig; then
    pub_ip=$(dig +short myip.opendns.com @resolver1.opendns.com +time=2 +tries=1 2>/dev/null || true)
  fi

  if [[ -n "$pub_ip" ]]; then
    pass "Public IPv4 address: ${pub_ip}"
  else
    warn "Unable to determine public IPv4 address"
  fi
}

check_dns() {
  section "4. DNS Resolution & Resolver Latency (${DNS_DOMAIN})"

  if has_cmd dig; then
    local server t_start t_end elapsed ans
    for server in "${DNS_SERVERS[@]}"; do
      t_start=$(now_ms)
      if ans=$(dig @"$server" "$DNS_DOMAIN" A +time=2 +tries=1 +short 2>/dev/null | head -n 1); then
        t_end=$(now_ms)
        elapsed=$((t_end - t_start))
        if [[ -n "$ans" ]]; then
          pass "Resolver @${server} -> ${ans} (${elapsed} ms)"
        else
          fail "Resolver @${server} returned empty answer for ${DNS_DOMAIN}"
        fi
      else
        fail "Resolver @${server} timed out or failed for ${DNS_DOMAIN}"
      fi
    done
  elif has_cmd nslookup; then
    local server
    for server in "${DNS_SERVERS[@]}"; do
      if nslookup "$DNS_DOMAIN" "$server" >/dev/null 2>&1; then
        pass "Resolver @${server} resolved ${DNS_DOMAIN} (via nslookup)"
      else
        fail "Resolver @${server} failed for ${DNS_DOMAIN}"
      fi
    done
  elif has_cmd getent; then
    if getent hosts "$DNS_DOMAIN" >/dev/null 2>&1; then
      pass "System resolver resolved ${DNS_DOMAIN} (via getent)"
    else
      fail "System resolver failed for ${DNS_DOMAIN}"
    fi
  else
    warn "No DNS lookup utility found (dig, nslookup, getent)"
  fi
}

check_tcp_ports() {
  section "5. TCP Port Reachability"

  local entry host port t_start t_end elapsed
  for entry in "${TCP_TARGETS[@]}"; do
    host="${entry%%:*}"
    port="${entry##*:}"

    if [[ -z "$host" || -z "$port" || "$host" == "$port" ]]; then
      warn "Invalid TCP target format '${entry}' (expected host:port)"
      continue
    fi

    t_start=$(now_ms)
    if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      t_end=$(now_ms)
      elapsed=$((t_end - t_start))
      pass "TCP ${host}:${port} is OPEN (${elapsed} ms)"
    else
      fail "TCP ${host}:${port} is CLOSED or FILTERED"
    fi
  done
}

check_http_endpoints() {
  section "6. HTTP/HTTPS Endpoint Checks"

  if ! has_cmd curl; then
    warn "'curl' not installed; skipping HTTP endpoint checks"
    return 0
  fi

  local url code time_total
  for url in "${HTTP_TARGETS[@]}"; do
    local result
    if result=$(curl -o /dev/null -sS -L --max-time 5 -w "%{http_code}|%{time_total}" "$url" 2>/dev/null); then
      code="${result%%|*}"
      time_total="${result##*|}"
      if [[ "$code" =~ ^[23][0-9]{2}$ ]]; then
        pass "${url} -> HTTP ${code} (${time_total}s)"
      else
        warn "${url} -> Unexpected HTTP ${code} (${time_total}s)"
      fi
    else
      fail "${url} -> Request failed or timed out"
    fi
  done
}

# -----------------------------------------------------------------------------
# Summary & Report Export
# -----------------------------------------------------------------------------
print_summary() {
  section "Diagnostic Summary"
  log_line "Passed: ${PASS_COUNT} | Warnings: ${WARN_COUNT} | Failed: ${FAIL_COUNT}" \
           "${C_GREEN}Passed: ${PASS_COUNT}${C_RESET} | ${C_YELLOW}Warnings: ${WARN_COUNT}${C_RESET} | ${C_RED}Failed: ${FAIL_COUNT}${C_RESET}"

  if [[ "$SAVE_REPORT" -eq 1 ]]; then
    mkdir -p "$REPORT_DIR"
    local outfile="${REPORT_DIR}/netcheck_$(date +%Y%m%d_%H%M%S).log"
    {
      printf "NetCheck Report v%s - %s\n" "$VERSION" "$(date -Is)"
      printf "Host: %s\n" "$(hostname 2>/dev/null || echo unknown)"
      printf "%s" "$REPORT_BUFFER"
    } > "$outfile"
    info "Saved report to ${outfile}"
  fi
}

reset_counters() {
  FAIL_COUNT=0
  WARN_COUNT=0
  PASS_COUNT=0
  REPORT_BUFFER=""
}

run_full_suite() {
  reset_counters
  log_line "NetCheck v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S')" \
           "${C_BOLD}NetCheck v${VERSION}${C_RESET} ${C_DIM}($(date '+%Y-%m-%d %H:%M:%S'))${C_RESET}"
  check_interfaces_and_gateway
  check_external_icmp
  check_public_ip
  check_dns
  check_tcp_ports
  check_http_endpoints
  print_summary
}

# -----------------------------------------------------------------------------
# Interactive Menu Mode
# -----------------------------------------------------------------------------
prompt_custom_target() {
  printf "\n"
  read -r -p "Enter hostname or IP to test (e.g. cloudflare.com): " custom_host
  if [[ -z "$custom_host" ]]; then
    warn "No host entered."
    return 0
  fi

  read -r -p "Enter TCP port to test [default: 443]: " custom_port
  custom_port="${custom_port:-443}"

  if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || (( custom_port < 1 || custom_port > 65535 )); then
    fail "Invalid port number: ${custom_port}"
    return 0
  fi

  reset_counters
  section "Custom Target Diagnostics: ${custom_host}:${custom_port}"

  local stats avg loss
  if stats=$(measure_ping "$custom_host"); then
    avg="${stats%%|*}"
    loss="${stats##*|}"
    pass "ICMP Ping to ${custom_host}: avg ${avg} ms, loss ${loss}%"
  else
    warn "ICMP Ping to ${custom_host} failed (ICMP may be blocked)"
  fi

  if has_cmd dig; then
    local resolved
    resolved=$(dig +short "$custom_host" A +time=2 +tries=1 2>/dev/null | head -n 1 || true)
    if [[ -n "$resolved" ]]; then
      pass "DNS A record for ${custom_host}: ${resolved}"
    fi
  fi

  if timeout 3 bash -c "exec 3<>/dev/tcp/${custom_host}/${custom_port}" 2>/dev/null; then
    pass "TCP port ${custom_port} on ${custom_host} is OPEN"
  else
    fail "TCP port ${custom_port} on ${custom_host} is CLOSED or FILTERED"
  fi
}

interactive_menu() {
  while true; do
    printf "\n%b========================================%b\n" "${C_CYAN}" "${C_RESET}"
    printf "%b   NetCheck v%s — Interactive Menu%b\n" "${C_BOLD}" "${VERSION}" "${C_RESET}"
    printf "%b========================================%b\n" "${C_CYAN}" "${C_RESET}"
    printf "  1) Run Full Network Diagnostics\n"
    printf "  2) Local Gateway & Interface Check\n"
    printf "  3) External Ping & Public IP Check\n"
    printf "  4) DNS Resolver Benchmark\n"
    printf "  5) TCP Ports & HTTP Endpoint Check\n"
    printf "  6) Test a Custom Host & Port\n"
    printf "  7) Run Full Suite & Save Log Report\n"
    printf "  0) Exit\n"
    printf "%b----------------------------------------%b\n" "${C_DIM}" "${C_RESET}"

    read -r -p "Select an option [0-7]: " choice

    case "$choice" in
      1)
        run_full_suite
        ;;
      2)
        reset_counters
        check_interfaces_and_gateway
        ;;
      3)
        reset_counters
        check_external_icmp
        check_public_ip
        ;;
      4)
        reset_counters
        check_dns
        ;;
      5)
        reset_counters
        check_tcp_ports
        check_http_endpoints
        ;;
      6)
        prompt_custom_target
        ;;
      7)
        SAVE_REPORT=1
        run_full_suite
        SAVE_REPORT=0
        ;;
      0|q|Q|exit)
        printf "Exiting NetCheck.\n"
        exit 0
        ;;
      *)
        printf "%bInvalid selection. Choose 0-7.%b\n" "${C_RED}" "${C_RESET}"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# CLI Help & Argument Parsing
# -----------------------------------------------------------------------------
show_help() {
  cat <<EOF
${SCRIPT_NAME} v${VERSION} — Interactive & CLI Linux Network Diagnostics

Usage:
  ./${SCRIPT_NAME} [OPTIONS]

Without options, launches the interactive menu.

Options:
  -a, --all            Run full non-interactive diagnostic suite and exit
  -d, --domain DOMAIN  Set target domain for DNS checks (default: ${DNS_DOMAIN})
  -t, --tcp HOST:PORT  Test a single TCP host:port and exit
  -s, --save           Save diagnostic report to ${REPORT_DIR}/
      --no-color       Disable ANSI terminal colors
  -v, --version        Show script version
  -h, --help           Show this help message

Examples:
  ./${SCRIPT_NAME}                        # Launch interactive menu
  ./${SCRIPT_NAME} --all                  # Run all checks non-interactively
  ./${SCRIPT_NAME} --all --save           # Run all checks and save log file
  ./${SCRIPT_NAME} -d archlinux.org -a    # Benchmark DNS using archlinux.org
  ./${SCRIPT_NAME} -t github.com:22       # Quick check if SSH port 22 is reachable
EOF
}

main() {
  load_config

  local mode="interactive"
  local single_tcp=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--all)
        mode="all"
        shift
        ;;
      -d|--domain)
        if [[ -z "${2:-}" ]]; then
          printf "Error: --domain requires an argument.\n" >&2
          exit 2
        fi
        DNS_DOMAIN="$2"
        shift 2
        ;;
      -t|--tcp)
        if [[ -z "${2:-}" ]]; then
          printf "Error: --tcp requires HOST:PORT.\n" >&2
          exit 2
        fi
        mode="single_tcp"
        single_tcp="$2"
        shift 2
        ;;
      -s|--save)
        SAVE_REPORT=1
        shift
        ;;
      --no-color)
        ENABLE_COLOR=0
        shift
        ;;
      -v|--version)
        printf "%s %s\n" "$SCRIPT_NAME" "$VERSION"
        exit 0
        ;;
      -h|--help)
        setup_colors
        show_help
        exit 0
        ;;
      *)
        printf "Unknown option: %s (use --help for usage)\n" "$1" >&2
        exit 2
        ;;
    esac
  done

  setup_colors

  case "$mode" in
    interactive)
      interactive_menu
      ;;
    all)
      run_full_suite
      [[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
      ;;
    single_tcp)
      TCP_TARGETS=("$single_tcp")
      check_tcp_ports
      [[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
      ;;
  esac
}

main "$@"
