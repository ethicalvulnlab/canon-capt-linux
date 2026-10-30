#!/usr/bin/env bash
# install-lbp6020.sh — Canon i-SENSYS LBP6020 (CAPT) installer for Debian/Kali/Ubuntu
#
# Usage:
#   sudo ./install-lbp6020.sh [/path/to/debs]
#
# The directory must contain the Canon CAPT amd64 packages:
#   cndrvcups-common_3.21-1_amd64.deb
#   cndrvcups-capt_2.71-1_amd64.deb
#
# See README.md (Steps 2 and 8) for obtaining the packages and for the
# 32-bit libxml2/ICU workaround required on current Kali/Debian.

set -euo pipefail

PRINTER="${PRINTER:-Canon_LBP6020}"
DEV="${DEV:-/dev/usb/lp0}"
PPD="/usr/share/cups/model/CNCUPSLBP6020CAPTK.ppd"
DEB_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

die()  { echo "✘  $*" >&2; exit 1; }
info() { echo "➜  $*"; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 $DEB_DIR"
[[ -c "$DEV" ]]   || die "$DEV not found — power on the printer and check the USB cable."

shopt -s nullglob
COMMON=( "$DEB_DIR"/cndrvcups-common_*_amd64*.deb )
CAPT=(   "$DEB_DIR"/cndrvcups-capt_*_amd64*.deb   )
shopt -u nullglob

[[ ${#COMMON[@]} -gt 0 ]] || die "cndrvcups-common .deb not found in $DEB_DIR"
[[ ${#CAPT[@]}   -gt 0 ]] || die "cndrvcups-capt .deb not found in $DEB_DIR"

info "Installing 32-bit popt (captfilter is 32-bit)"
dpkg --add-architecture i386
apt-get update -qq
apt-get install -y libpopt0:i386

info "Installing Canon CAPT driver"
dpkg -i "${COMMON[0]}" "${CAPT[0]}"
ldconfig

[[ -f "$PPD" ]] || die "PPD missing after install: $PPD"

info "Creating CUPS queue '$PRINTER'"
lpadmin -x "$PRINTER" 2>/dev/null || true
lpadmin -p "$PRINTER" -P "$PPD" -v ccp://localhost:59687 \
        -E -o printer-is-shared=false
lpadmin -d "$PRINTER"

info "Registering device with ccpd"
ccpdadmin -x "$PRINTER" >/dev/null 2>&1 || true
ccpdadmin -p "$PRINTER" -o "$DEV"

info "Creating /var/ccpd FIFOs"
mkdir -p /var/ccpd
chown lp:lp /var/ccpd
for i in 0 1 2 3 4 5 6 7; do
    [ -p "/var/ccpd/fifo$i" ] || mkfifo -m 660 "/var/ccpd/fifo$i"
    chown lp:lp "/var/ccpd/fifo$i"
done

info "Installing ccpd.service"
cat > /etc/systemd/system/ccpd.service <<'EOF'
[Unit]
Description=Canon CAPT Printer Daemon
After=network.target cups.service
Wants=cups.service

[Service]
Type=forking
ExecStart=/usr/sbin/ccpd
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ccpd
systemctl restart ccpd
sleep 2

if ! systemctl is-active --quiet ccpd; then
    die "ccpd failed to start — see: journalctl -u ccpd -n 50"
fi

info "Checking 32-bit libraries"
if ldd /usr/bin/captmon 2>/dev/null | grep -q 'not found'; then
    echo "⚠  Missing 32-bit libraries:"
    ldd /usr/bin/captmon | grep 'not found'
    echo "   Follow Step 8 in README.md, then: sudo systemctl restart ccpd"
else
    echo "✔  All 32-bit libraries resolved"
fi

info "Ports"
ss -tln | grep -E ':(59687|59787)' || echo "⚠  ccpd ports not listening"

info "Printing test page"
lp -d "$PRINTER" -t "Canon LBP6020 test page" /usr/share/cups/data/testprint || true

echo
echo "✔  Done. Check status with:"
echo "   lpstat -p -v"
echo "   systemctl status ccpd"
echo "   captstatusui -P $PRINTER"
