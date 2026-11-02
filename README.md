# bizhub C3851 - printer setup

Target: print from this laptop **and** from an Android/iPhone, without
fighting the USB cable every time.

- Printer: **Konica Minolta bizhub C3851** (serial `00ECFD3A`)
- USB ID: `132b:2342`, device ID says `CMD:PS,POSTSCRIPT,PCL`
- Laptop: Arch/Omarchy, CUPS 2.4, Wi-Fi via the phone hotspot

## Files

| File | Purpose |
|---|---|
| `setup.sh` | one-shot setup; run with `sudo bash ~/km-printer/setup.sh` |
| `km-printer` | helper command, installed to `/usr/local/bin` |

## What setup.sh does

1. installs `dnsmasq` (DHCP for the direct cable link)
2. installs the official KM driver already in
   `~/Downloads/bizhub-c3351-installer` (PPD + `KMbeuEmpPS.pl` filter)
3. makes `enp0s25` a "shared" link, so a printer plugged into it gets an address
4. turns on CUPS sharing (`Port 631`, `@LOCAL`) and opens ufw for it
5. finds the printer by mDNS, then by scanning the cable link
6. creates:
   - `KM-C3851` - network queue (when the printer is found on the network)
   - `KM-C3851-USB` - permanent USB fallback queue
7. installs `km-printer`

Re-running it is safe; it updates the queues instead of duplicating them.

## Commands

```bash
km-printer status   # queues, device, jobs
km-printer find     # locate the printer
km-printer test     # print a test page
km-printer web      # open the printer's settings page
km-printer fix      # re-point the queue after the printer's IP changed
```

## Phones

Both phones must be on the same network as the printer (or as this laptop).

**Android (vivo V21)** - Settings -> Connected devices -> Connection
preferences -> Printing -> *Default Print Service* (or install *Mopria Print
Service*). The shared queue shows up in the print menu.

**iPhone** - print dialog -> Printer -> the queue appears via AirPrint.

Konica Minolta **Mobile Print** adds scanning to the phone and can add the
printer by IP when automatic discovery is blocked (Android hotspots often
block mDNS between clients).

## If the printer is not on the network

The printer needs one of:

1. the optional Wireless LAN kit (UK-216) to join the phone hotspot, or
2. an Ethernet cable to a router, or
3. an Ethernet cable to this laptop (the laptop then shares it).

## The A4 -> Letter fix (added 01 Nov 2026)

**Symptom:** jobs from the phone were accepted by CUPS, converted and sent
over USB ("Receiving" on the printer screen) but no paper; CUPS logged them
as completed. Laptop test pages printed fine.

**Cause:** the printer tray holds **Letter** paper, but documents sent by
the phone keep their original **A4 (595x842)** geometry. The bizhub waits
for an A4 tray that doesn't exist and silently discards the job. Laptop
jobs printed because they defaulted to Letter.

**Fix:** `~/km-printer/fix-a4-letter.sh` (run with sudo). It installs
`/usr/lib/cups/filter/A4ToLetter` (Ghostscript `pdfwrite -dPDFFitPage`,
which rescales any PDF to Letter) and swaps the
`application/pdf -> application/vnd.cups-pdf` mime rule in
`/usr/share/cups/mime/cupsfilters-individual.convs` from `pdftopdf (66)`
to `A4ToLetter (33)`. Photos from the phone go through `imagetopdf` first
and get scaled the same way.

**Verify chain:** after printing a job,
`grep 'filters for job' /var/log/cups/error_log | tail -1` should list
`A4ToLetter -> pdftops -> KMbeuEmpPS.pl`.

**Re-apply after** any `cups-filters` package upgrade (the mime rule
reverts). `/etc/cups` and `/usr/share/cups/mime` are backed up with
timestamps by the script before each change.

Test document: `~/km-printer/test-a4.pdf` (genuine A4, 2 pages).
