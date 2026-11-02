#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  fix-a4-letter.sh - scaler so A4 documents print on this Letter tray
#
#  Why: the bizhub C3851's tray holds Letter paper, while documents sent by
#  the phone (and many PDFs) keep their original A4 geometry. The printer
#  accepts the USB data ("Receiving") then silently discards it, because no
#  A4 tray exists.
#
#  How: this installs a CUPS filter "A4ToLetter" (Ghostscript pdfwrite with
#  -dPDFFitPage) that rescales every incoming PDF onto US Letter. It replaces
#  the standard pdftopdf leg in the filter chain, so the Konica Minolta
#  vendor filter stays last, as designed.
#
#  Run with:   sudo bash ~/km-printer/fix-a4-letter.sh
#  Safe to re-run. Backs up everything it touches.
#
#  NOTE: a future cups-filters package upgrade reverts the mime rule.
#  Re-running this script re-applies it.
# ---------------------------------------------------------------------------
set -euo pipefail

WRAP=/usr/lib/cups/filter/A4ToLetter
PPD=/etc/cups/ppd/C3851Series.ppd
CONVS=/usr/share/cups/mime/cupsfilters-individual.convs
TESTPDF=/home/biggiesam/km-printer/test-a4.pdf

[[ ${EUID} -eq 0 ]] || { echo "run with: sudo bash ~/km-printer/fix-a4-letter.sh"; exit 1; }
[[ -f $PPD ]] || { echo "queue PPD not found: $PPD"; exit 1; }
[[ -f $CONVS ]] || { echo "mime convs not found: $CONVS"; exit 1; }

# 1. Install / refresh the wrapper filter -----------------------------------
#    (temp files in /var/tmp - always exists; /tmp/opencode gets wiped)
cat > "$WRAP" <<'EOF'
#!/usr/bin/env bash
# A4ToLetter - CUPS filter: rescale incoming PDF onto US Letter paper.
# This machine's bizhub tray holds Letter; phone jobs are A4 and get
# silently dropped without this filter.
set -u
T=$(mktemp /var/tmp/a4toletter.XXXXXX)
in="$T"
[[ $# -ge 6 && -f "${6:-}" ]] && in="$6"
cleanup(){ [[ "$in" == "$T" ]] && rm -f "$T"; }
trap cleanup EXIT
[[ "$in" == "$T" ]] && cat > "$T"
exec gs -q -dNOPAUSE -dBATCH -dPDFSETTINGS=/prepress \
    -sDEVICE=pdfwrite -dPDFFitPage -sPAPERSIZE=letter \
    -dCompatibilityLevel=1.5 -o - "$in"
EOF
chmod 755 "$WRAP"
echo "ok: filter installed at $WRAP"

# 2. Offline-verify the wrapper DOES scale (before touching CUPS) -----------
if [[ -f $TESTPDF ]]; then
    OUT1=$(mktemp /var/tmp/a4check.XXXXXX.pdf)
    if "$WRAP" 1 root offline-verify 1 "" "$TESTPDF" > "$OUT1"; then
        sz=$(pdfinfo "$OUT1" 2>/dev/null | awk '/Page size/ {print $3, $5}')
        rm -f "$OUT1"
        echo "ok: wrapper offline output pagesize = ${sz:-UNKNOWN} (want 612 792)"
    else
        echo "FAIL: wrapper verification errored - NOT changing CUPS. Aborting."
        rm -f "$OUT1"
        exit 1
    fi
fi

# 3. Revert the earlier PPD cupsFilter2 experiments --------------------------
cp -a "$PPD" "${PPD}.bak.$(date +%Y%m%d%H%M%S)"
sed -i '/cupsFilter2.*A4ToLetter/d' "$PPD"
echo "ok: PPD cleaned (no cupsFilter2 A4ToLetter lines)"

# 4. Patch the mime rule: pdftopdf (66) becomes A4ToLetter (33) -------------
cp -a "$CONVS" "${CONVS}.bak.$(date +%Y%m%d%H%M%S)"
sed -i '/^application\/pdf[[:space:]].*application\/vnd\.cups-pdf[[:space:]]*66[[:space:]]*pdftopdf/s|^|# [A4ToLetter patch] |' "$CONVS"
sed -i '/A4ToLetter$/d' "$CONVS"
printf 'application/pdf\tapplication/vnd.cups-pdf\t\t33\tA4ToLetter\n' >> "$CONVS"
echo "ok: mime rule swapped (A4ToLetter wins the pdf -> cups-pdf leg)"
grep -n 'application/pdf.*A4ToLetter\|A4ToLetter patch' "$CONVS"

# 5. Restart CUPS, enable the queue, clear stale jobs ------------------------
systemctl restart cups && sleep 2
cancel -a C3851Series 2>/dev/null || true
cupsenable C3851Series 2>/dev/null || true
lpstat -p C3851Series

# 6. Controlled real-world test: genuine A4 document ------------------------
if [[ -f $TESTPDF ]]; then
    lp -d C3851Series -t "A4->Letter FINAL test" "$TESTPDF" \
        && echo "TEST SENT - the 2-page test should print on paper now."
else
    echo "(no $TESTPDF to print - send any job to test)"
fi
