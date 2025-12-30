#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dnswatchdog"
SRC_SCRIPT="dns_watchdog.sh"
SERVICE_TEMPLATE="packaging/dnswatchdog.service"
LOGROTATE_TEMPLATE="packaging/logrotate.dnswatchdog"

INSTALL_DIR="/usr/local/lib/${APP_NAME}"
RUNNER="/usr/local/sbin/${APP_NAME}-run"
CTL="/usr/local/bin/${APP_NAME}"
SYSTEMD_UNIT="/etc/systemd/system/${APP_NAME}.service"
LOGROTATE_DST="/etc/logrotate.d/${APP_NAME}"

DETAIL_LOG="/var/log/dns_watchdog_detail.log"
SUMMARY_LOG="/var/log/dns_watchdog_summary.log"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

require_files_present() {
  [[ -f "${SRC_SCRIPT}" ]] || { echo "Fehlt: ${SRC_SCRIPT}"; exit 1; }
  [[ -f "${SERVICE_TEMPLATE}" ]] || { echo "Fehlt: ${SERVICE_TEMPLATE}"; exit 1; }
  [[ -f "${LOGROTATE_TEMPLATE}" ]] || { echo "Fehlt: ${LOGROTATE_TEMPLATE}"; exit 1; }
}

install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dnsutils iproute2
}

install_files() {
  mkdir -p "${INSTALL_DIR}"
  install -m 0755 "${SRC_SCRIPT}" "${INSTALL_DIR}/${SRC_SCRIPT}"

  # Runner
  cat > "${RUNNER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_DIR}/${SRC_SCRIPT}"
EOF
  chmod 0755 "${RUNNER}"

  # Control command: dnswatchdog start/stop/status/logs
  cat > "${CTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
svc="dnswatchdog.service"

usage() {
  cat <<USAGE
Usage:
  dnswatchdog start|stop|restart|status
  dnswatchdog enable|disable
  dnswatchdog logs          (tail -f summary)
  dnswatchdog logs-detail   (tail -f detail)
USAGE
}

cmd="${1:-}"
case "$cmd" in
  start|stop|restart|status|enable|disable)
    exec systemctl "$cmd" "$svc"
    ;;
  logs)
    exec tail -n 200 -f /var/log/dns_watchdog_summary.log
    ;;
  logs-detail)
    exec tail -n 200 -f /var/log/dns_watchdog_detail.log
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unbekannter Befehl: $cmd"
    usage
    exit 2
    ;;
esac
EOF
  chmod 0755 "${CTL}"
}

install_logs() {
  touch "${DETAIL_LOG}" "${SUMMARY_LOG}"
  chmod 0644 "${DETAIL_LOG}" "${SUMMARY_LOG}"
}

install_systemd() {
  sed "s|@@RUNNER@@|${RUNNER}|g" "${SERVICE_TEMPLATE}" > "${SYSTEMD_UNIT}"
  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}.service"
}

install_logrotate() {
  install -m 0644 "${LOGROTATE_TEMPLATE}" "${LOGROTATE_DST}"
}

uninstall_all() {
  systemctl disable --now "${APP_NAME}.service" 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT}"
  systemctl daemon-reload || true

  rm -f "${CTL}" "${RUNNER}"
  rm -rf "${INSTALL_DIR}"
  rm -f "${LOGROTATE_DST}"

  echo "Deinstallation fertig. Logs bleiben absichtlich erhalten:"
  echo "  ${DETAIL_LOG}"
  echo "  ${SUMMARY_LOG}"
}

main() {
  need_root

  if [[ "${1:-}" == "--uninstall" ]]; then
    uninstall_all
    exit 0
  fi

  require_files_present
  install_deps_debian
  install_files
  install_logs
  install_logrotate
  install_systemd

  echo ""
  echo "✅ ${APP_NAME} installiert & gestartet."
  echo "Befehle:"
  echo "  dnswatchdog status"
  echo "  dnswatchdog logs"
  echo "  dnswatchdog logs-detail"
  echo "  dnswatchdog restart"
}

main "$@"
