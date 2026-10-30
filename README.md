# Canon CAPT on Linux — i-SENSYS LBP6020 Driver Fix

**Get the Canon i-SENSYS LBP6020 (and similar CAPT-based LBP printers) working on Debian / Kali / Ubuntu.**

While written for the **LBP6020**, most steps apply to other Canon CAPT-based i-SENSYS LBP models.

> Tested on **Kali GNU/Linux Rolling 2026.3** · kernel 6.19 · CUPS 2.4.18 · Canon CAPT 2.71

[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Kali%20%7C%20Ubuntu-informational)](https://www.kali.org)
[![CUPS](https://img.shields.io/badge/CUPS-2.4-blue)](https://openprinting.github.io/cups/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-ethicalvulnlab-181717?logo=github&logoColor=white)](https://github.com/ethicalvulnlab)

---

## Table of Contents

- [Symptoms](#symptoms)
- [Root Causes](#root-causes)
- [Requirements](#requirements)
- [Step 1 — Identify the Printer](#step-1--identify-the-printer)
- [Step 2 — Get the Canon CAPT Driver](#step-2--get-the-canon-capt-driver)
- [Step 3 — Install the 32-bit Runtime and Driver](#step-3--install-the-32-bit-runtime-and-driver)
- [Step 4 — Create the CUPS Queue](#step-4--create-the-cups-queue)
- [Step 5 — Register the Device with ccpd](#step-5--register-the-device-with-ccpd)
- [Step 6 — Create the FIFO Directory](#step-6--create-the-fifo-directory)
- [Step 7 — Run ccpd as a systemd Service](#step-7--run-ccpd-as-a-systemd-service)
- [Step 8 — Install the Missing 32-bit Libraries](#step-8--install-the-missing-32-bit-libraries)
- [Step 9 — Verify and Print a Test Page](#step-9--verify-and-print-a-test-page)
- [Final Working Configuration](#final-working-configuration)
- [Troubleshooting](#troubleshooting)
- [Why a Generic PPD Never Works](#why-a-generic-ppd-never-works)
- [Repository Files](#repository-files)
- [License](#license)
- [Author](#author)

---

## Symptoms

You may see one or more of these:

- `lsusb` shows `04a9:2771 Canon CAPT USB Device`, but nothing prints.
- A CUPS queue exists, but jobs stay in **"now printing"** forever.
- `lpstat -p` reports **"Unplugged or turned off"** even though the printer is on.
- `lpstat -l -o` shows:
  - `Can't connect to CCPD: Connection refused`
  - or `ccp send_data error, exit`
- `ccpdadmin` lists the printer but the **FIFO path is empty**.
- The queue's model is something unrelated (e.g. *Samsung ML-1710*) instead of a Canon CAPT PPD.

## Root Causes

| Symptom | Real cause |
|---|---|
| Queue exists, no output | Wrong PPD (not the Canon CAPT one) |
| Driver "installed" but missing | `cndrvcups-capt` / `cndrvcups-common` removed (`rc` state) |
| `Connection refused` / `send_data error` | `ccpd` not running, or not listening on port 59687 |
| `ccpd` runs but USB traffic is zero | `/var/ccpd` FIFOs missing |
| `bidiNew() Error!` in `strace` | 32-bit helper can't load `libxml2.so.2` / `libicuuc.so.72` |

The LBP6020 is a **host-based CAPT** printer. It requires Canon's proprietary CAPT driver, the `ccpd` daemon, and a **32-bit runtime** — even on a 64-bit system.

---

## Requirements

- Root access (`sudo`)
- CUPS installed (`cups`, `cups-client`)
- i386 architecture enabled
- The Canon CAPT driver packages (`.deb`, amd64):
  - `cndrvcups-common_3.21-1_amd64.deb`
  - `cndrvcups-capt_2.71-1_amd64.deb`

```bash
sudo dpkg --add-architecture i386
sudo apt update
```

---

## Step 1 — Identify the Printer

```bash
lsusb | grep -i canon
# Bus 001 Device 002: ID 04a9:2771 Canon CAPT USB Device

lpstat -p -v
# printer Canon_LBP6020 ...
# device for Canon_LBP6020: usb://Canon/LBP6020?serial=...

ls -l /dev/usb/lp0
# crw-rw---- 1 root lp 180, 0 ... /dev/usb/lp0

dpkg -l | grep cndrv
# rc  cndrvcups-capt    (rc = removed, config remains)
```

If `/dev/usb/lp0` does not exist:

```bash
sudo modprobe usblp
ls /dev/usb/lp*
```

---

## Step 2 — Get the Canon CAPT Driver

Download **"CAPT Printer Driver for Linux V2.71"** for the LBP6020 from Canon's support site
(*i-SENSYS LBP6020 → Drivers → Linux*). The archive contains both 32-bit and 64-bit `.deb` files.

> **Do not commit the `.deb` files to your repository** — they are Canon's proprietary binaries.
> The included `.gitignore` already excludes them.

### Fix legacy dependency names (Debian/Kali)

Modern Debian/Kali no longer ship `libgcc1` or `libcups2` (they are now `libgcc-s1` and `libcups2t64`).
Repack the packages so `dpkg` stays consistent:

```bash
mkdir -p build-common build-capt

dpkg-deb -R cndrvcups-common_3.21-1_amd64.deb build-common
sed -i 's/libcups2 | libcupsys2 (>= 1.2.7)/libcups2t64 | libcups2/' build-common/DEBIAN/control
dpkg-deb --root-owner-group -b build-common cndrvcups-common_3.21-1_amd64-fixed.deb

dpkg-deb -R cndrvcups-capt_2.71-1_amd64.deb build-capt
sed -i 's/libgcc1 (>= 1:4.1.1-12)/libgcc-s1/' build-capt/DEBIAN/control
dpkg-deb --root-owner-group -b build-capt cndrvcups-capt_2.71-1_amd64-fixed.deb
```

---

## Step 3 — Install the 32-bit Runtime and Driver

`captfilter` is a **32-bit** binary, so it needs `libpopt0:i386`:

```bash
sudo apt install -y libpopt0:i386
sudo dpkg -i cndrvcups-common_3.21-1_amd64-fixed.deb \
             cndrvcups-capt_2.71-1_amd64-fixed.deb
sudo ldconfig
```

Verify the important files exist:

```bash
ls -l /usr/sbin/ccpd /usr/sbin/ccpdadmin \
      /usr/bin/captfilter \
      /usr/lib/cups/filter/pstocapt3 \
      /usr/share/cups/model/CNCUPSLBP6020CAPTK.ppd
```

> If `dpkg` complains about dependencies, use `--force-depends` **only as a last resort** —
> repacking (Step 2) is the clean fix.

---

## Step 4 — Create the CUPS Queue

Remove the broken queue and recreate it with the correct CAPT PPD:

```bash
sudo lpadmin -x Canon_LBP6020 2>/dev/null || true

sudo lpadmin -p Canon_LBP6020 \
  -P /usr/share/cups/model/CNCUPSLBP6020CAPTK.ppd \
  -v ccp://localhost:59687 \
  -E -o printer-is-shared=false

sudo lpadmin -d Canon_LBP6020
```

Check:

```bash
lpstat -p Canon_LBP6020 -v
# device for Canon_LBP6020: ccp://localhost:59687
```

---

## Step 5 — Register the Device with ccpd

```bash
sudo ccpdadmin -p Canon_LBP6020 -o /dev/usb/lp0
sudo ccpdadmin
```

Expected output:

```
 Entry Num  : Spooler        : Backend : FIFO path          : Device Path   : Status
 [0]        : Canon_LBP6020  : ccp     : //localhost:59687  : /dev/usb/lp0  :
```

---

## Step 6 — Create the FIFO Directory

The package's `postinst` leaves this commented out, so create it manually:

```bash
sudo mkdir -p /var/ccpd
sudo chown lp:lp /var/ccpd

for i in 0 1 2 3 4 5 6 7; do
  sudo mkfifo -m 660 /var/ccpd/fifo$i
  sudo chown lp:lp /var/ccpd/fifo$i
done
```

---

## Step 7 — Run ccpd as a systemd Service

The shipped `/etc/init.d/ccpd` has no usable systemd unit, so create one:

```bash
sudo tee /etc/systemd/system/ccpd.service >/dev/null <<'EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable --now ccpd
sudo systemctl restart ccpd
```

---

## Step 8 — Install the Missing 32-bit Libraries

This is the step almost every guide misses.

`ccpd` spawns a 32-bit helper (`captmon`) for bidirectional communication.
On current Kali/Debian it fails because:

- Canon needs **`libxml2.so.2`**, but Debian now ships **`libxml2-16`** (soname 16)
- That old libxml2 needs **`libicuuc.so.72`**, while the system has a newer ICU

Diagnose with:

```bash
ldd /usr/bin/captmon | grep 'not found'
```

If you see `libxml2.so.2` and/or `libicuuc.so.72`, extract the old 32-bit libraries
from Debian bookworm — this is **side-by-side**, no `dpkg` changes:

```bash
cd /tmp

# 32-bit libxml2 (soname 2)
curl -fsSLO http://ftp.debian.org/debian/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3~deb12u6_i386.deb
dpkg-deb -x libxml2_2.9.14+dfsg-1.3~deb12u6_i386.deb libxml2
sudo install -m 644 libxml2/usr/lib/i386-linux-gnu/libxml2.so.2.9.14 /usr/lib/i386-linux-gnu/
sudo ln -sf libxml2.so.2.9.14 /usr/lib/i386-linux-gnu/libxml2.so.2

# 32-bit ICU 72
curl -fsSLO http://ftp.debian.org/debian/pool/main/i/icu/libicu72_72.1-3+deb12u1_i386.deb
dpkg-deb -x libicu72_72.1-3+deb12u1_i386.deb icu
sudo install -m 644 icu/usr/lib/i386-linux-gnu/libicuuc.so.72.1 \
                    icu/usr/lib/i386-linux-gnu/libicudata.so.72.1 \
                    /usr/lib/i386-linux-gnu/
sudo ln -sf libicuuc.so.72.1  /usr/lib/i386-linux-gnu/libicuuc.so.72
sudo ln -sf libicudata.so.72.1 /usr/lib/i386-linux-gnu/libicudata.so.72

sudo ldconfig
```

> Package versions in the Debian pool change over time.
> If a URL 404s, list the directory and pick the current i386 build.

Verify everything resolves:

```bash
ldd /usr/bin/captmon | grep 'not found' || echo "All libraries resolved"
```

Restart the daemon:

```bash
sudo systemctl restart ccpd
```

---

## Step 9 — Verify and Print a Test Page

### Check that ccpd actually talks to the printer

```bash
cat /sys/bus/usb/devices/1-2/urbnum
sleep 3
cat /sys/bus/usb/devices/1-2/urbnum
```

The counter **must increase**. If it stays frozen, `ccpd` is not opening the device
(go back to Step 8).

> Find the right path with:
> `readlink /sys/class/usbmisc/lp0` → `.../usb1/1-2/1-2:1.0/usbmisc/lp0`

### Check the ports

```bash
ss -tln | grep -E ':59687|:59787'
```

Both should be listening: `59687` (data) and `59787` (status).

### Print

```bash
lp -d Canon_LBP6020 -t "LBP6020 test page" /usr/share/cups/data/testprint
lpstat -o Canon_LBP6020
```

The job should complete and the page should come out.

---

## Final Working Configuration

| Item | Value |
|---|---|
| Queue | `Canon_LBP6020` (default) |
| PPD | `CNCUPSLBP6020CAPTK.ppd` |
| Device URI | `ccp://localhost:59687` |
| USB device | `/dev/usb/lp0` (`04a9:2771`) |
| Service | `ccpd.service` — enabled, active |
| Driver | Canon CAPT 2.71 / common 3.21 |

Useful commands:

```bash
lpstat -p -v                     # queue + device
ccpdadmin                        # registered printers
systemctl status ccpd            # daemon state
captstatusui -P Canon_LBP6020    # Canon status monitor
sudo systemctl restart ccpd      # restart after changes
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `ccp send_data error, exit` | `ccpd` not running or port 59687 not listening → `systemctl restart ccpd`; check `ss -tln` |
| `Can't connect to CCPD: Connection refused` | Same as above — `ccpd` is down or crashed |
| Job stuck at "now printing", `urbnum` frozen | Missing 32-bit libs → `ldd /usr/bin/captmon \| grep 'not found'` |
| Queue says "Unplugged or turned off" | Re-plug USB, `sudo modprobe usblp`, then `sudo cupsenable Canon_LBP6020` |
| Printed garbage / wrong driver | Recreate the queue with the CAPT PPD (Step 4) |
| `ccpdadmin` shows no printer | Re-run Step 5 |
| After unplug/replug nothing works | `sudo systemctl restart ccpd` (and `cups`) |

Debugging tips:

```bash
sudo strace -f -e trace=openat,read,write /usr/sbin/ccpd   # see which files/libs it opens
sudo dmesg | grep -i usblp                                  # USB kernel messages
```

---

## Why a Generic PPD Never Works

CAPT printers are **host-based**: they have no PostScript/PCL interpreter inside.
The host must convert the job with Canon's `pstocapt3` filter and its firmware modules
(`/usr/share/ccpd/*.BIN`), then stream it over USB via `ccpd`.

A generic PPD (e.g. Samsung ML-1710, Gutenprint, `everywhere`) will accept jobs but the
printer cannot understand the data — so nothing prints, or you get blank/garbage pages.

---

## Repository Files

```
canon-capt-linux/
├── README.md              ← this guide
├── install-lbp6020.sh     ← automated installer (driver + queue + service)
├── LICENSE                ← MIT
└── .gitignore
```

### Automated install

Place the two Canon `.deb` files (fixed, see Step 2) next to the script, then:

```bash
sudo ./install-lbp6020.sh /path/to/debs
```

The script installs the driver, creates the queue, registers the device, sets up
`ccpd.service`, and prints a test page. It also warns you if the 32-bit libraries
from Step 8 are still missing.

---

## License

[MIT](LICENSE) — free to use, modify, and share.

---

## Author

**ethicalvulnlab**

- GitHub: [@ethicalvulnlab](https://github.com/ethicalvulnlab)
- Repository: [canon-capt-linux](https://github.com/ethicalvulnlab/canon-capt-linux)

If this guide saved you hours of debugging, consider giving the repo a ⭐ — it helps
other people find it.

Thanks for reading — and happy printing! 🖨️
