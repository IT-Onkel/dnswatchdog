#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
DETAIL_LOG="/var/log/dns_watchdog_detail.log"
SUMMARY_LOG="/var/log/dns_watchdog_summary.log"

# dnsmasq listening IP (LAN IP)
LOCAL_DNS="192.168.100.4"

# Reference resolvers (bypass dnsmasq)
UPSTREAM_DNS=( "1.1.1.1" "8.8.8.8" )

# Test domains (stable & diverse)
TEST_DOMAINS=(
  "google.com"
  "cloudflare.com"
  "heise.de"
  "github.com"
  "microsoft.com"
  "amazon.com"
)

# Frequencies:
TEST_INTERVAL_SEC=20        # every 20s run full test batch
SUMMARY_INTERVAL_SEC=300    # every 5 minutes write summary

# dig behavior
DIG_TIMEOUT_SEC=2
DIG_TRIES=1
DO_AAAA_TESTS=true

# DNSSEC hint (AD flag) - optional info, not hard failure
DO_DNSSEC_NOTE=true
DNSSEC_TEST_DOMAIN="cloudflare.com"

# =========================
# Internals
# =========================
DIG_BIN=""
SS_BIN=""
RUN_ID="$(date +%s)"

# Window vars
dnssec_note=""
l_ok=0; l_to=0; l_sf=0; l_nx=0; l_rf=0; l_err=0; l_unk=0
u_ok=0; u_to=0; u_sf=0; u_nx=0; u_rf=0; u_err=0; u_unk=0
tests_run=0
batches_run=0

ts() { date -Is; }
log_detail() { printf '%s %s\n' "$(ts)" "$1" >> "$DETAIL_LOG"; }
log_summary() { printf '%s %s\n' "$(ts)" "$1" >> "$SUMMARY_LOG"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

resolve_tools() {
  DIG_BIN="$(command -v dig || true)"
  SS_BIN="$(command -v ss || true)"
}

ensure_deps_debian() {
  resolve_tools

  if [[ -z "$DIG_BIN" ]]; then
    if is_root; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y dnsutils >/dev/null 2>&1 || true
      resolve_tools
    fi
  fi

  if [[ -z "$SS_BIN" ]]; then
    if is_root; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y iproute2 >/dev/null 2>&1 || true
      resolve_tools
    fi
  fi

  if [[ -z "$DIG_BIN" ]]; then
    echo "ERROR: dig fehlt weiterhin. Installiere 'dnsutils'." >&2
    exit 1
  fi
}

svc_status_dnsmasq() {
  if have_cmd systemctl; then
    systemctl is-active --quiet dnsmasq && echo "active" || echo "inactive"
  else
    pgrep -x dnsmasq >/dev/null 2>&1 && echo "active" || echo "inactive"
  fi
}

port53_listening_udp() {
  if [[ -n "${SS_BIN:-}" ]]; then
    if ss -lpun 2>/dev/null | grep -qE ':(53)\s'; then
      echo "yes"
    else
      echo "no"
    fi
  else
    echo "unknown"
  fi
}

# returns: TOKEN qtime_ms=.. status=..
dns_query() {
  local resolver="$1" domain="$2" rrtype="${3:-A}" extra="${4:-}"

  local out rc status qtime
  rc=0
  out="$("$DIG_BIN" @"$resolver" "$domain" "$rrtype" \
    +tries="$DIG_TRIES" +time="$DIG_TIMEOUT_SEC" +stats +nocmd +noquestion +nocomments $extra 2>&1)" || rc=$?

  # Parsing without pipefail traps
  status="$(sed -n 's/.* status: \([A-Z]*\).*/\1/p' <<<"$out" | head -n1 || true)"
  qtime="$(awk '/^;; Query time:/{print $4; exit}' <<<"$out" 2>/dev/null || true)"

  if grep -qiE 'connection timed out|no servers could be reached' <<<"$out"; then
    echo "TIMEOUT qtime_ms=${qtime:-NA} status=${status:-NA}"
    return 0
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR rc=${rc} qtime_ms=${qtime:-NA} status=${status:-NA}"
    return 0
  fi

  case "${status:-}" in
    NOERROR)  echo "OK qtime_ms=${qtime:-NA} status=NOERROR" ;;
    NXDOMAIN) echo "NXDOMAIN qtime_ms=${qtime:-NA} status=NXDOMAIN" ;;
    SERVFAIL) echo "SERVFAIL qtime_ms=${qtime:-NA} status=SERVFAIL" ;;
    REFUSED)  echo "REFUSED qtime_ms=${qtime:-NA} status=REFUSED" ;;
    *)        echo "UNKNOWN qtime_ms=${qtime:-NA} status=${status:-NA}" ;;
  esac
}

dnssec_note_local() {
  local out
  out="$("$DIG_BIN" @"$LOCAL_DNS" "$DNSSEC_TEST_DOMAIN" A +dnssec +stats 2>&1 || true)"
  if grep -qE 'flags:.*\bad\b' <<<"$out"; then
    echo "dnssec_ad=1"
  else
    echo "dnssec_ad=0"
  fi
}

reset_window() {
  l_ok=0; l_to=0; l_sf=0; l_nx=0; l_rf=0; l_err=0; l_unk=0
  u_ok=0; u_to=0; u_sf=0; u_nx=0; u_rf=0; u_err=0; u_unk=0
  tests_run=0
  batches_run=0
}

inc_counter() {
  local scope="$1" token="$2"
  case "$scope:$token" in
    local:OK)      ((l_ok+=1)) ;;
    local:TIMEOUT) ((l_to+=1)) ;;
    local:SERVFAIL)((l_sf+=1)) ;;
    local:NXDOMAIN)((l_nx+=1)) ;;
    local:REFUSED) ((l_rf+=1)) ;;
    local:ERROR)   ((l_err+=1)) ;;
    local:UNKNOWN) ((l_unk+=1)) ;;
    upstream:OK)      ((u_ok+=1)) ;;
    upstream:TIMEOUT) ((u_to+=1)) ;;
    upstream:SERVFAIL)((u_sf+=1)) ;;
    upstream:NXDOMAIN)((u_nx+=1)) ;;
    upstream:REFUSED) ((u_rf+=1)) ;;
    upstream:ERROR)   ((u_err+=1)) ;;
    upstream:UNKNOWN) ((u_unk+=1)) ;;
  esac
}

run_and_log() {
  local scope="$1" resolver="$2" domain="$3" rr="$4" extra="${5:-}"
  local r token
  r="$(dns_query "$resolver" "$domain" "$rr" "$extra")"
  token="$(awk '{print $1}' <<<"$r" 2>/dev/null || echo "UNKNOWN")"
  inc_counter "$scope" "$token"
  ((tests_run+=1))
  log_detail "RUN=${RUN_ID} scope=${scope} resolver=${resolver} domain=${domain} rr=${rr} result=\"${r}\""
}

# =========================
# Main Loop
# =========================
ensure_deps_debian

stop_requested=0
trap 'stop_requested=1; log_detail "RUN=${RUN_ID} signal=TERM stop_requested=1"' TERM INT

reset_window
start_ts="$(date +%s)"
last_summary_ts="$start_ts"
next_test_ts="$start_ts"

log_detail "RUN=${RUN_ID} START local_dns=${LOCAL_DNS} upstream_dns=${UPSTREAM_DNS[*]} test_interval=${TEST_INTERVAL_SEC}s summary_interval=${SUMMARY_INTERVAL_SEC}s"
log_summary "RUN=${RUN_ID} START local_dns=${LOCAL_DNS} test_interval=${TEST_INTERVAL_SEC}s summary_interval=${SUMMARY_INTERVAL_SEC}s"

while [[ "$stop_requested" -eq 0 ]]; do
  now="$(date +%s)"

  if (( now >= next_test_ts )); then
    dnsmasq_state="$(svc_status_dnsmasq)"
    listen53="$(port53_listening_udp)"
    nxdomain_test="this-should-not-exist-${now}.invalid"
    ((batches_run+=1))

    log_detail "RUN=${RUN_ID} BATCH_START dnsmasq_state=${dnsmasq_state} port53_udp=${listen53} batch=${batches_run}"

    for d in "${TEST_DOMAINS[@]}"; do
      run_and_log "local" "$LOCAL_DNS" "$d" "A"
      if [[ "$DO_AAAA_TESTS" == "true" ]]; then
        run_and_log "local" "$LOCAL_DNS" "$d" "AAAA"
      fi
    done

    run_and_log "local" "$LOCAL_DNS" "." "NS"
    run_and_log "local" "$LOCAL_DNS" "$nxdomain_test" "A"

    for up in "${UPSTREAM_DNS[@]}"; do
      for d in "${TEST_DOMAINS[@]}"; do
        run_and_log "upstream" "$up" "$d" "A"
        if [[ "$DO_AAAA_TESTS" == "true" ]]; then
          run_and_log "upstream" "$up" "$d" "AAAA"
        fi
      done
      run_and_log "upstream" "$up" "." "NS"
    done

    if [[ "$DO_DNSSEC_NOTE" == "true" ]]; then
      dnssec_note="$(dnssec_note_local)"
      log_detail "RUN=${RUN_ID} DNSSEC_NOTE ${dnssec_note} domain=${DNSSEC_TEST_DOMAIN}"
    fi

    log_detail "RUN=${RUN_ID} BATCH_END tests_run_window=${tests_run} batches_run_window=${batches_run}"
    next_test_ts=$(( now + TEST_INTERVAL_SEC ))
  fi

  if (( now - last_summary_ts >= SUMMARY_INTERVAL_SEC )); then
    dnsmasq_state="$(svc_status_dnsmasq)"
    listen53="$(port53_listening_udp)"
    window_sec=$(( now - last_summary_ts ))
    if [[ "$DO_DNSSEC_NOTE" == "true" ]]; then
      dnssec_note="$(dnssec_note_local)"
    else
      dnssec_note=""
    fi

    log_summary "RUN=${RUN_ID} SUMMARY window=${window_sec}s batches=${batches_run} tests=${tests_run} dnsmasq_state=${dnsmasq_state} port53_udp=${listen53} ${dnssec_note} | local ok=${l_ok} timeout=${l_to} servfail=${l_sf} nxdomain=${l_nx} refused=${l_rf} error=${l_err} unknown=${l_unk} | upstream ok=${u_ok} timeout=${u_to} servfail=${u_sf} nxdomain=${u_nx} refused=${u_rf} error=${u_err} unknown=${u_unk}"

    reset_window
    last_summary_ts="$now"
  fi

  sleep 1
done

log_summary "RUN=${RUN_ID} STOP"
log_detail "RUN=${RUN_ID} STOP"
exit 0
