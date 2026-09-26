"""Constants for Find My Rooms."""

DOMAIN = "findmy_rooms"

# Tracker and room settings live outside the integration folder so updating
# the code never wipes them. Contains PUBLIC advertisement keys only.
CONFIG_FILE = "findmy_rooms.json"

APPLE_COMPANY_ID = 0x004C
OFFLINE_FINDING_PREFIX = b"\x12\x19"  # type 0x12 (Offline Finding), length 25

DEFAULT_SETTINGS = {
    "poll_seconds": 5,  # how often proxy data is read
    "window_seconds": 45,  # RSSI samples older than this are ignored
    "lost_after_seconds": 120,  # not heard this long -> fall back to Find My state
    "switch_margin_db": 5,  # a new room must be this much stronger ...
    "switch_confirm_seconds": 10,  # ... for this long before we switch
    "min_write_seconds": 30,  # rewrite unchanged state at most this often
    # dB added to a room's RSSI before comparing, e.g. {"Bedroom 2": -6}
    # to stop a hub that hears through walls from stealing neighbouring rooms.
    "rssi_offsets": {},
}

# Status byte bits 6-7 in the advertisement.
BATTERY_LEVELS = {0x00: "full", 0x40: "medium", 0x80: "low", 0xC0: "critical"}
