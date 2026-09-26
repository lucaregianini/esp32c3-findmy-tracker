#!/bin/bash
# Make one more DIY Find My tracker: keys -> firmware -> flash -> Home Assistant file.
#
# Usage:  ~/Projects/c3-findmy-fw/tools/new-tracker.sh <name> [serial-port]
#   name: lowercase letters, digits, underscores (e.g. backpack, bike_1).
#         Home Assistant will call it device_tracker.findmy_<name>.
#   serial-port: optional; auto-detected when exactly one C3 is plugged in.
#
# Re-running with an existing name reuses its keys (use it to reflash a board).
set -euo pipefail

NAME="${1:-}"
PORT="${2:-}"
# Override any of these with environment variables (see README "Setup").
FW="$(cd "$(dirname "$0")/.." && pwd)"                               # this repo
KEYDIR="${KEYDIR:-$HOME/Projects/go-haystack}"                        # go-haystack keys
FETCH="${FETCH:-$HOME/Projects/findmy-fetch}"                         # venv with FindMy.py
IDF_ENV="${IDF_ENV:-$HOME/.espressif/tools/activate_idf_v5.4.4.sh}"   # ESP-IDF 5.4
HAYSTACK="${HAYSTACK:-$HOME/go/bin/haystack}"                         # go-haystack binary

if [[ ! "$NAME" =~ ^[a-z0-9_]+$ ]]; then
    echo "Usage: $0 <name> [serial-port]   (name: lowercase letters, digits, _)"
    exit 1
fi

echo "==> 1/5 Keys for '$NAME'"
cd "$KEYDIR"
if [ -f "$NAME.keys" ]; then
    echo "    $NAME.keys already exists - reusing it (same tracker, same keys)."
else
    PWD="$KEYDIR" "$HAYSTACK" keys "$NAME"
    echo "    Created $NAME.keys and $NAME.json"
fi
chmod 600 "$NAME.keys" "$NAME.json"

echo "==> 2/5 Firmware with these keys"
python3 "$FW/tools/gen_keys_h.py" "$KEYDIR/$NAME.keys"
# ESP-IDF's activate script only works when its caller is named "bash" (it
# exits otherwise), so run idf.py through a bash -c wrapper.
[ -f "$IDF_ENV" ] || { echo "ESP-IDF not found ($IDF_ENV)"; exit 1; }
idf() { bash -c 'source "$1" > /dev/null 2>&1; shift; idf.py "$@"' bash "$IDF_ENV" "$@"; }
cd "$FW"
idf build > "$FW/build-$NAME.log" 2>&1 || { echo "Build failed - see $FW/build-$NAME.log"; exit 1; }
echo "    Built (log: build-$NAME.log)"

echo "==> 3/5 Flash"
if [ -z "$PORT" ]; then
    PORTS=(/dev/cu.usbmodem*)
    if [ ! -e "${PORTS[0]}" ]; then
        echo "    No C3 found. Plug it in with USB (batteries OUT) and run again."; exit 1
    fi
    if [ "${#PORTS[@]}" -ne 1 ]; then
        echo "    Several boards plugged in: ${PORTS[*]}"
        echo "    Unplug the others, or pass the port: $0 $NAME /dev/cu.usbmodemXXXX"; exit 1
    fi
    PORT="${PORTS[0]}"
fi
read -r -p "    Flash '$NAME' onto $PORT? This erases that board. [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "    Cancelled - nothing flashed."; exit 1; }
idf -p "$PORT" erase-flash flash > "$FW/flash-$NAME.log" 2>&1 || {
    echo "    Flash failed - see $FW/flash-$NAME.log"
    echo "    If the board is asleep: hold BOOT, tap RST, release BOOT, then run again."; exit 1; }
echo "    Flashed."

echo "==> 4/5 Home Assistant key file"
"$FETCH/.venv/bin/python" - "$KEYDIR/$NAME.json" "$KEYDIR/$NAME.findmy.json" "$NAME" <<'EOF'
import base64, json, os, sys
from findmy.accessory import FixedRollingKeyPairAccessory
src, out, name = sys.argv[1:4]
d = json.load(open(src)); d = d[0] if isinstance(d, list) else d
keys = [base64.b64decode(k) for k in [d["privateKey"]] + d["additionalKeys"]]
FixedRollingKeyPairAccessory(private_keys=keys, name=name, identifier=str(d["id"])).to_json(out)
os.chmod(out, 0o600)
print(f"    {out} ({len(keys)} keys)")
EOF

echo "==> 5/5 Check it is broadcasting"
echo "    In Terminal:  cd \"$KEYDIR\" && \"$HAYSTACK\" scan"
echo "    (look for a strong line ending '- battery full'; Ctrl-C to stop)"
echo
echo "Done. Next, in Home Assistant: Settings > Devices & services > FindMy > Add device >"
echo "  'Rolling-key device with pre-generated keys', name: $NAME, file:"
echo "  $KEYDIR/$NAME.findmy.json"
echo "Then add device_tracker.findmy_$NAME to your dashboards and to the"
echo "  'fetch every 5 min while away' automation (see README)."

echo
read -r -p "Add '$NAME' to room detection (Near <room>) now? [Y/n] " rooms
if [[ ! "$rooms" =~ ^[Nn] ]]; then
    "$(dirname "$0")/add-to-rooms.sh" "$NAME"
fi
