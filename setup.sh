#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Konica Minolta bizhub C3851 - one-shot setup for this laptop + phones
#
#  Run it with:   sudo bash ~/km-printer/setup.sh
#
#  What it does:
#    1. installs dnsmasq (small DHCP server for the direct cable link)
#    2. installs the official Konica Minolta driver that is already in
#       ~/Downloads/bizhub-c3351-installer (PPD + PostScript filter)
#    3. makes the laptop's Ethernet port hand an address to the printer
#    4. turns on CUPS printer sharing, so phones can print via the laptop
#    5. finds the printer on the network (mDNS, then a direct-link scan)
#    6. creates a permanent network queue + a permanent USB fallback queue
#    7. installs the "km-printer" helper command
# ---------------------------------------------------------------------------
set -uo pipefail

CR=$'\033[0m'; CB=$'\033[1;36m'; CG=$'\033[1;32m'; CY=$'\033[1;33m'; CE=$'\033[1;31m'
step(){ printf '\n%s==>%s %s\n' "$CB" "$CR" "$*"; }
ok(){   printf '%s ok %s %s\n' "$CG" "$CR" "$*"; }
warn(){ printf '%s !! %s %s\n' "$CY" "$CR" "$*"; }
die(){  printf '%sERR%s %s\n' "$CE" "$CR" "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run it with sudo:   sudo bash $0"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -d $REAL_HOME ]] || REAL_HOME="/home/$REAL_USER"

PRINTER="KM-C3851"
PRINTER_USB="KM-C3851-USB"
IFACE="enp0s25"
LINK_NET="10.42.0"
USB_URI_DEFAULT='usb://KONICA%20MINOLTA/C3851Series?serial=00ECFD3A'
CONF=/etc/cups/cupsd.conf
KM_MODEL="KonicaMinolta/KMbeuC3851ux.ppd.gz"
GENERIC="drv:///sample.drv/generic.ppd"
DRV_TAR="$REAL_HOME/Downloads/bizhub-c3351-installer/KMbeuUXv1_27_multi_language.tar.gz"
DRV_UNPACKED="/tmp/opencode/kmdrv/KMbeuUXv1_27_multi_language"

probe(){ timeout 0.5 bash -c "echo >/dev/tcp/$1/$2" 2>/dev/null; }
link_up(){ [[ -r /sys/class/net/$IFACE/carrier && $(cat /sys/class/net/$IFACE/carrier) == 1 ]]; }

# Scan one /24 for a host answering IPP or RAW printing. Used only when mDNS
# does not find anything (some printers/hotspots block multicast).
scan_net(){
    local base=$1 ip
    for ip in $(seq 2 254); do ping -c1 -W1 "${base}.${ip}" >/dev/null 2>&1 & done
    wait 2>/dev/null
    for ip in $(ip neigh show 2>/dev/null | awk '{print $1}' \
            | grep -E "^${base//./\\.}\.[0-9]+$"); do
        if probe "$ip" 631 || probe "$ip" 9100; then
            printf 'ipp://%s/ipp/print\n' "$ip"; return 0
        fi
    done
    return 1
}

# Locate the printer. Returns a full IPP URI (stable .local name when mDNS
# works, otherwise a scanned IP address).
find_uri(){
    local uri wifi_base
    uri=$(ippfind -T 4 -r -p 2>/dev/null | grep -v '/printers/' \
          | grep -viE 'localhost|127\.0\.0\.1' | head -n1)
    if [[ -n $uri ]]; then printf '%s\n' "$uri"; return 0; fi

    # printer plugged straight into this laptop?
    if link_up; then
        scan_net "$LINK_NET" && return 0
    fi

    # printer on the same Wi-Fi as the laptop (phone hotspot)?
    wifi_base=$(ip -4 -o addr show wlo1 2>/dev/null \
                | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3)
    if [[ -n $wifi_base ]]; then
        scan_net "$wifi_base" && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
step "1/6  Packages"
missing=()
for p in dnsmasq perl ghostscript; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
done
if ((${#missing[@]})); then
    pacman -S --needed --noconfirm "${missing[@]}" >/dev/null 2>&1 \
        && ok "installed: ${missing[*]}" || warn "could not install: ${missing[*]}"
else
    ok "everything already installed"
fi

# ---------------------------------------------------------------------------
step "2/6  Official Konica Minolta driver"
DRV_DIR=""
TMP_DRV=""
if [[ -f /usr/share/cups/model/$KM_MODEL && -x /usr/lib/cups/filter/KMbeuEmpPS.pl ]]; then
    ok "official driver already installed"
elif [[ -f $DRV_TAR ]]; then
    TMP_DRV=$(mktemp -d)
    if tar xzf "$DRV_TAR" -C "$TMP_DRV" 2>/dev/null; then
        DRV_DIR="$TMP_DRV/KMbeuUXv1_27_multi_language"
    else
        rm -rf "$TMP_DRV"; TMP_DRV=""
    fi
elif [[ -f $DRV_UNPACKED/KMbeuC3851ux.ppd ]]; then
    DRV_DIR="$DRV_UNPACKED"
fi

if [[ -n $DRV_DIR && -f $DRV_DIR/KMbeuC3851ux.ppd ]]; then
    install -Dm644 "$DRV_DIR/KMbeuC3851ux.ppd" \
        /usr/share/cups/model/KonicaMinolta/KMbeuC3851ux.ppd
    gzip -f /usr/share/cups/model/KonicaMinolta/KMbeuC3851ux.ppd
    install -Dm755 "$DRV_DIR/KMbeuEmpPS.pl" /usr/lib/cups/filter/KMbeuEmpPS.pl
    install -Dm644 "$DRV_DIR/KMbeuEnc.pm"   /usr/lib/cups/filter/KMbeuEnc.pm
    ok "driver installed (PPD + PostScript filter)"
    [[ -n $TMP_DRV ]] && rm -rf "$TMP_DRV"
elif [[ -f /usr/share/cups/model/$KM_MODEL ]]; then
    ok "driver model found"
else
    warn "official driver files not found - falling back to generic PostScript"
    KM_MODEL="$GENERIC"
fi

# ---------------------------------------------------------------------------
step "3/6  Direct cable link on $IFACE"
if nmcli -t -f NAME con show | grep -qx "km-printer-link"; then
    nmcli con mod km-printer-link \
        ipv4.method shared ipv4.addresses "${LINK_NET}.1/24" \
        ipv6.method ignore connection.autoconnect yes >/dev/null 2>&1
else
    nmcli con add type ethernet ifname "$IFACE" con-name km-printer-link \
        ipv4.method shared ipv4.addresses "${LINK_NET}.1/24" \
        ipv6.method ignore connection.autoconnect yes >/dev/null 2>&1
fi
nmcli con up km-printer-link >/dev/null 2>&1 || true

if link_up; then
    ok "cable link is up - the printer gets an address automatically"
else
    warn "no physical link on $IFACE (carrier 0)."
    warn "Check: printer switched on? cable clicked into the printer's LAN"
    warn "port and this laptop? try another Ethernet cable."
fi

# ---------------------------------------------------------------------------
step "4/6  Printer sharing for phones"
cupsctl --share-printers --remote-any >/dev/null 2>&1 || warn "cupsctl failed"

if ! grep -qE '^(Port 631|Listen (0\.0\.0\.0|\[::\]|:|\*):631)' "$CONF"; then
    cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    if grep -qE '^Listen localhost:631' "$CONF"; then
        sed -i 's/^Listen localhost:631/Port 631/' "$CONF"
    else
        printf '\nPort 631\n' >> "$CONF"
    fi
    ok "CUPS now listens on the local network (port 631)"
else
    ok "CUPS already listens on the local network"
fi

systemctl enable --now cups avahi-daemon >/dev/null 2>&1
systemctl restart cups || die "cups did not start (journalctl -u cups)"
ok "cups + avahi running"

if systemctl is-active --quiet ufw; then
    for cidr in "${LINK_NET}.0/24" $(ip -4 -o addr show wlo1 2>/dev/null \
            | awk '{print $4}' | head -n1); do
        [[ -n $cidr ]] || continue
        ufw allow from "$cidr" to any port 631  proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port 5353 proto udp >/dev/null 2>&1
    done
    ok "firewall opened for printing on the local network"
fi

# ---------------------------------------------------------------------------
step "5/6  Looking for the printer"
URI=""
if URI=$(find_uri); then
    ok "found printer: $URI"
else
    warn "printer not found yet"
fi

# ---------------------------------------------------------------------------
step "6/6  Print queues"

# Create a queue, falling back to the generic PostScript driver if the vendor
# PPD is rejected for any reason.
add_queue(){
    local name=$1 uri=$2 model=$3
    lpadmin -p "$name" -E -v "$uri" -m "$model" \
        -o printer-is-shared=true -o printer-error-policy=retry-job >/dev/null 2>&1 && return 0
    if [[ $model != "$GENERIC" ]]; then
        lpadmin -p "$name" -E -v "$uri" -m "$GENERIC" \
            -o printer-is-shared=true -o printer-error-policy=retry-job >/dev/null 2>&1 && return 0
    fi
    return 1
}

USB_URI=$(lpinfo -v 2>/dev/null | awk '$1=="direct" && $2 ~ /^usb:\/\/KONICA/ {print $2; exit}')
[[ -n $USB_URI ]] || USB_URI=$USB_URI_DEFAULT
if add_queue "$PRINTER_USB" "$USB_URI" "$KM_MODEL"; then
    ok "USB queue ready ($PRINTER_USB)"
else
    warn "could not create the USB queue"
fi

if [[ -n $URI ]]; then
    if add_queue "$PRINTER" "$URI" "$KM_MODEL"; then
        ok "network queue ready ($PRINTER)"
        lpadmin -d "$PRINTER" >/dev/null 2>&1
    else
        warn "network queue could not be created"
    fi
else
    lpadmin -d "$PRINTER_USB" >/dev/null 2>&1
fi

install -m 0755 "$(dirname "$0")/km-printer" /usr/local/bin/km-printer \
    && ok "installed the 'km-printer' command"

# ---------------------------------------------------------------------------
printf '\n%s---------------- summary ----------------%s\n' "$CB" "$CR"
lpstat -p -d 2>&1
echo
if [[ -n $URI ]]; then
    HOST=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$URI")
    printf 'Printer settings page : http://%s/\n' "$HOST"
else
    printf '%sNext steps:%s\n' "$CB" "$CR"
    printf '  1. switch the printer on\n'
    printf '  2. plug a network (Ethernet) cable into the printer LAN port\n'
    printf '     and into this laptop - it must click in\n'
    printf '  3. rerun:  sudo bash %s\n' "$0"
fi
printf 'Test print            : km-printer test\n'
printf 'Status                : km-printer status\n'
echo
