#!/usr/bin/env bash
set -euo pipefail

# dnswatchdog installer for Debian
# Installs:
# - /usr/local/lib/dnswatchdog/dns_watchdog.sh
# - /usr/local/sbin/dnswatchdog-run   (real executable)
# - /usr/local/bin/dnswatchdog        (simple control command)
# - systemd service: dnswatchdog.service
# - log files in /var/log/

APP_NAME="dnswatchdog"
SRC_SCRIPT="dns_watchdog.sh"
SERVICE_FILE="packaging/dnswatchdog.service"

INSTALL_DIR="/usr/local/lib/${APP_NAME}"
RUNNER="/usr/local/sbin/${APP_NAME}-run"
CTL="/usr/local/bin/${APP_NAME}"
SYSTEMD_UNIT="/etc/systemd/system/${APP_NAME}.service"

DETAIL_LOG="/var/log/dns_watchdog_detail.log"
SUMMARY_LOG="/var/log/dns_watchdog_summary.log"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

require_files_present() {
  if [[ ! -f "${SRC_SCRIPT}" ]]; then
    echo "Fehlt: ${SRC_SCRIPT} (erwartet im Repo-Root)."
    exit 1
  fi
  if [[ ! -f "${SERVICE_FILE}" ]]; then
    echo "Fehlt: ${SERVICE_FILE}."
    exit 1
  fi
}

install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dnsutils iproute2
}

install_files() {
  mkdir -p "${INSTALL_DIR}"
  install -m 0755 "${SRC_SCRIPT}" "${INSTALL_DIR}/${SRC_SCRIPT}"

  # Runner: feste Pfade, damit systemd sauber starten kann
  cat > "${RUNNER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_DIR}/${SRC_SCRIPT}"
EOF
  chmod 0755 "${RUNNER}"

  # Control command: einfacher Befehl "dnswatchdog ..."
  cat > "${CTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

svc="dnswatchdog.service"

usage() {
  cat <<USAGE
Usage:
  dnswatchdog start|stop|restart|status
  dnswatchdog logs          (tail -f summary)
  dnswatchdog logs-detail   (tail -f detail)
  dnswatchdog enable|disable
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
  # Service template aus Repo übernehmen
  # und ggf. Runner-Pfad eintragen
  sed "s|@@RUNNER@@|${RUNNER}|g" "${SERVICE_FILE}" > "${SYSTEMD_UNIT}"

  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}.service"
}

uninstall_all() {
  systemctl disable --now "${APP_NAME}.service" 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT}"
  systemctl daemon-reload || true

  rm -f "${CTL}" "${RUNNER}"
  rm -rf "${INSTALL_DIR}"

  echo "Deinstallation fertig. Logs bleiben absichtlich erhalten:"
  echo "  ${DETAIL_LOG}"
  echo "  ${SUMMARY_LOG}"
}

main() {
  need_root

  case "${1:-}" in
    --uninstall)
      uninstall_all
      exit 0
      ;;
  esac

  require_files_present
  install_deps_debian
  install_files
  install_logs
  install_systemd

  echo ""
  echo "✅ ${APP_NAME} installiert & gestartet."
  echo ""
  echo "Befehle:"
  echo "  dnswatchdog status"
  echo "  dnswatchdog logs"
  echo "  dnswatchdog logs-detail"
  echo "  dnswatchdog restart"
}

main "$@"
