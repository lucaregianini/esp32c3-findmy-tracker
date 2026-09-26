# Find My Rooms (Home Assistant custom integration)

Shows which room hub each DIY Find My tracker is near: `sensor.<name>_near`
("Near Kitchen"), falling back to the hass-FindMy state ("Home"/"Away") when
no hub has heard it for 2 minutes. Room hubs are ESPHome Bluetooth proxies.

- Code: `custom_components/findmy_rooms/` -> copy to `/config/custom_components/`
  on HA, restart HA, then Settings > Devices & services > Add > Find My Rooms.
- Config: `/config/findmy_rooms.json` (see `findmy_rooms.example.json`):
  trackers (PUBLIC advertisement keys only), `rooms_by_source` (proxy BLE MAC
  -> label), `rooms_by_name` (ESPHome name -> label), `settings`
  (e.g. `rssi_offsets: {"Bedroom 2": -6}` to damp a hub that hears
  through walls). Edits to the JSON need only a reload of the integration;
  code changes need an HA restart.
- New tracker: `tools/new-tracker.sh <name>` offers it at the end, or run
  `tools/add-to-rooms.sh <name>` on its own.

Proxy hubs run passive scanning that starts only after WiFi connects
(`wifi: on_connect: esp32_ble_tracker.start_scan`), because continuous
scanning stopped ESP32-C3 SuperMini hubs joining WiFi at boot.
