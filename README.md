# xerox-phaser-3125-linux

Fix for a Xerox Phaser 3125 that prints nothing on Linux, despite CUPS
reporting every job as successful.

## Symptoms

The printer is connected, detected, and shows no fault. Jobs vanish:

- `lpstat` reports the job as `completed`
- `job-state-reasons` is `job-completed-successfully`
- the USB backend exits 0
- `/var/log/cups/error_log` is silent
- no paper comes out

The only trace is `total 0` in `/var/log/cups/page_log`.

## Cause

CUPS auto-selects the only foomatic PPD whose name matches this model family,
**`Xerox Phaser 3124 Foomatic/gdi`**. That is the wrong driver — the 3124 and
3125 are not the same class of device:

| Model | Firmware |
|---|---|
| Phaser **3124** | host-based GDI only |
| Phaser **3125** | PCL5e, PCL6 and PostScript |

The 3125 reports its languages over USB as `CMD:PCL5E,PCL6,POSTSCRIPT`. The
`gdi` driver emits Samsung host-based raster instead. Rendering a page through
each driver's filter chain and reading the PJL header shows the mismatch:

| Driver | Emits | Printer implements it? |
|---|---|---|
| `Xerox Phaser 3124 Foomatic/gdi` | `@PJL ENTER LANGUAGE = SMART` | **no** |
| `Generic PCL 6/PCL XL Printer Foomatic/pxlmono` | `@PJL ENTER LANGUAGE = PCLXL` | yes |

`SMART` is not a language this printer speaks, so it discards every job and
returns to idle without raising a fault. Nothing in the stack notices.

## Fix

```sh
./setup.sh            # configure the queue and print a test page
./setup.sh --no-test  # configure only
```

The script points the queue at a generic PCL-XL driver, enables it, makes it
the default destination, and prints a test page. Ghostscript rasterises
locally, so the printer receives plain PCL6.

Set `QUEUE=name` to override the queue name (default `Phaser-3125`).

Equivalent by hand:

```sh
lpadmin -p Phaser-3125 \
        -v "$(lpinfo -v | awk '/[Pp]haser.*3125/{print $2}')" \
        -m foomatic:Generic-PCL_6_PCL_XL_Printer-pxlmono.ppd -E
lpadmin -d Phaser-3125
```

PCL-XL rather than the printer's PostScript interpreter: Ghostscript does the
rasterising, which this printer's firmware handles more reliably. If you prefer
PostScript, substitute `-m drv:///sample.drv/generic.ppd`.

## Don't use the CUPS "Print Test Page" button

It is broken independently of the driver. `/usr/share/cups/data/testprint` is a
`#PDF-BANNER` descriptor, and the banner path fails under cups-filters 2.x:

```
cfFilterChain: bannertopdf completed with status 0.
cfFilterChain: pdftopdf completed with status 1.
universal filter failed.
```

The job dies with 0 bytes sent *and leaves the queue stopped*, so the next job
you submit silently sits there too. Recover with `cupsenable Phaser-3125`.

`setup.sh` prints `default-testpage.pdf` directly, bypassing the banner
machinery. Any ordinary PDF works too.

## Requirements

```sh
# Arch
sudo pacman -S cups cups-filters foomatic-db foomatic-db-engine ghostscript
# Debian/Ubuntu
sudo apt install cups cups-filters foomatic-db foomatic-db-engine ghostscript
```

`lpadmin` may work without `sudo` if you are in the CUPS `SystemGroup`; the
script tries unprivileged first and escalates only if CUPS refuses.

## Licence

MIT
