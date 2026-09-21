#!/usr/bin/env bash
#
# Set up a Xerox Phaser 3125 on Linux (CUPS).
#
# CUPS auto-selects "Xerox Phaser 3124 Foomatic/gdi" for this printer, which is
# wrong: the 3124 is host-based GDI only, while the 3125 speaks PCL5e, PCL6 and
# PostScript. The gdi driver emits "@PJL ENTER LANGUAGE = SMART", the printer
# does not implement it, so every job is silently discarded -- jobs report
# "completed", no error is logged, and nothing prints.
#
# This installs a generic PCL-XL queue instead and prints a test page.
#
# Usage: ./setup.sh [--no-test]
#
set -euo pipefail

QUEUE=${QUEUE:-Phaser-3125}
PPD=foomatic:Generic-PCL_6_PCL_XL_Printer-pxlmono.ppd
TESTPAGE=/usr/share/cups/data/default-testpage.pdf

info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[31m err\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${1:-} == --no-test ]] && DO_TEST=0 || DO_TEST=1
[[ -n ${1:-} && ${1:-} != --no-test ]] && die "Usage: $0 [--no-test]"

# lpadmin is permitted without sudo for members of the CUPS SystemGroup.
# Try unprivileged first, escalate only if CUPS refuses.
as_admin() { "$@" 2>/dev/null || sudo "$@"; }

for t in lpadmin lpstat lpinfo lp; do
    command -v "$t" >/dev/null || die "Missing '$t'. Install the CUPS client tools."
done

# --- 1. scheduler -----------------------------------------------------------

if ! lpstat -r 2>/dev/null | grep -q 'is running'; then
    info "Starting cupsd..."
    sudo systemctl enable --now cups.service cups.socket
    sleep 2
    lpstat -r 2>/dev/null | grep -q 'is running' || die "Could not start cupsd."
fi
ok "cupsd is running"

# --- 2. find the printer ----------------------------------------------------

URI=$(lpinfo -v 2>/dev/null | awk '/[Pp]haser.*3125/{print $2; exit}')
[[ -n $URI ]] || die "No Phaser 3125 found. Check it is powered on and connected."
ok "Found printer"

# --- 3. driver --------------------------------------------------------------

lpinfo -m 2>/dev/null | grep -qF "$PPD" \
    || die "PPD '$PPD' not available. Install foomatic-db and foomatic-db-engine."

info "Configuring queue '$QUEUE' with a PCL-XL driver..."
as_admin lpadmin -p "$QUEUE" -v "$URI" -m "$PPD" -E
as_admin cupsenable "$QUEUE" || true
as_admin cupsaccept "$QUEUE" || true
ok "Queue configured"

# Without a default destination, bare `lp file` fails and some desktop
# applications show no printer at all.
if ! lpstat -d 2>/dev/null | grep -q ': '; then
    as_admin lpadmin -d "$QUEUE"
    ok "Set '$QUEUE' as the default destination"
fi

# --- 4. test page -----------------------------------------------------------

(( DO_TEST )) || { printf '\nDone. Queue %s is ready.\n' "$QUEUE"; exit 0; }

# Deliberately not /usr/share/cups/data/testprint: that file is a #PDF-BANNER
# descriptor, and the banner path (bannertopdf -> pdftopdf) fails under
# cups-filters 2.x, killing the job with 0 bytes sent and leaving the queue
# stopped. Printing the PDF directly bypasses it.
[[ -r $TESTPAGE ]] || die "Test page not found at $TESTPAGE"

info "Printing test page..."
lp -d "$QUEUE" -t "CUPS Test Page" "$TESTPAGE" >/dev/null || die "Failed to submit test page."

for _ in $(seq 1 20); do
    [[ -z $(lpstat -o "$QUEUE" 2>/dev/null) ]] && break
    sleep 2
done

if lpstat -p "$QUEUE" 2>/dev/null | grep -q disabled; then
    die "Queue stopped -- the job hit a filter error. See: sudo tail -50 /var/log/cups/error_log"
fi

ok "Test page sent"
printf '\nDone. Queue %s is ready.\n' "$QUEUE"
