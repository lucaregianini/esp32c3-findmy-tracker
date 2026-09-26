#!/bin/bash
# Add a tracker to room detection ("Near Kitchen" etc.) in Home Assistant.
#
# Usage:  tools/add-to-rooms.sh <name> ["Display Name"]
#   name: same name as new-tracker.sh (e.g. backpack). Creates sensor.<name>_near.
#   Display Name: optional, how it reads in HA (default: name, capitalised).
#
# Only PUBLIC advertisement keys leave the Mac. Re-running updates the tracker.
# Needs: SSH access to Home Assistant (Advanced SSH & Web Terminal add-on, key
# login, host alias in ~/.ssh/config; set HA_SSH if it is not "ha") and the
# Find My Rooms integration installed. Protection mode can stay on.
set -euo pipefail

NAME="${1:?usage: add-to-rooms.sh <name> [\"Display Name\"]}"
DISPLAY="${2:-}"
KEYS="${KEYDIR:-$HOME/Projects/go-haystack}/$NAME.keys"
HA_SSH="${HA_SSH:-ha}"
[ -f "$KEYS" ] || { echo "No key file $KEYS (run new-tracker.sh $NAME first)"; exit 1; }

# Public keys only, as a JSON list.
PUBLIC=$(python3 - "$KEYS" <<'EOF'
import base64, json, sys
keys = [l.split(":", 1)[1].strip() for l in open(sys.argv[1]) if l.startswith("Advertisement key:")]
assert keys and all(len(base64.b64decode(k)) == 28 for k in keys), "no valid advertisement keys"
print(json.dumps(keys))
EOF
)
echo "==> $NAME: $(echo "$PUBLIC" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') public keys"

# Update /config/findmy_rooms.json on HA (keeps a .bak), then reload the integration.
ssh "$HA_SSH" "sudo python3 - '$NAME' '$DISPLAY' '$PUBLIC'" <<'EOF'
import json, shutil, sys
name, display, keys = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
p = "/config/findmy_rooms.json"
try:
    shutil.copy(p, p + ".bak")
    c = json.load(open(p))
except FileNotFoundError:  # first tracker: start an empty config
    c = {"trackers": [], "rooms_by_source": {}, "rooms_by_name": {}, "settings": {}}
entry = next((t for t in c["trackers"] if t["id"] == name), None)
if entry is None:
    entry = {"id": name}
    c["trackers"].append(entry)
    print(f"    added {name}")
else:
    print(f"    updated {name}")
entry["name"] = display or entry.get("name") or name.replace("_", " ").title()
entry["find_my_entity"] = f"device_tracker.findmy_{name}"
entry["keys"] = keys
json.dump(c, open(p, "w"), indent=2)
EOF

ssh "$HA_SSH" 'T=$(cat /run/s6/container_environment/SUPERVISOR_TOKEN); H="Authorization: Bearer $T"
E=$(python3 -c "import json; print(next(e[\"entry_id\"] for e in json.load(open(\"/config/.storage/core.config_entries\"))[\"data\"][\"entries\"] if e[\"domain\"]==\"findmy_rooms\"))")
curl -s -o /dev/null -w "==> reload: HTTP %{http_code}\n" -X POST -H "$H" http://supervisor/core/api/config/config_entries/entry/$E/reload'

echo
echo "Done: sensor.${NAME}_near appears in HA within a few seconds."
echo "It reads \"Near <room>\" once a room hub hears the tracker."
