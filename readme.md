# dnswatchdog

Continuous DNS watchdog for dnsmasq networks (Debian-focused).

- Runs comprehensive DNS tests every 20s
- Writes detailed logs + 5-minute summary logs
- Installs as a systemd service
- Provides `dnswatchdog` control command

## Install (Debian)

```bash
git clone https://github.com/IT-Onkel/dnswatchdog.git
cd dnswatchdog
sudo bash install.sh
