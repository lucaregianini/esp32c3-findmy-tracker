"""Find My Rooms: which room hub is each DIY Find My tracker near.

Reads the advertisements that ESPHome Bluetooth proxies forward to Home
Assistant, recognises our trackers by their PUBLIC keys, and exposes one
sensor per tracker ("Near Laundry", or the Find My state when not heard).

HA's Bluetooth manager does not re-fire callbacks for unchanged adverts (ours
stay identical for 5 min per key), so we poll each proxy's own per-address
timestamps and RSSI instead, which update on every advertisement.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import timedelta

from homeassistant.components import bluetooth
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import ConfigEntryNotReady
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.event import async_track_time_interval

from .const import APPLE_COMPANY_ID, CONFIG_FILE, DEFAULT_SETTINGS, DOMAIN
from .engine import Estimate, RoomEstimator, TrackerKeys

_LOGGER = logging.getLogger(__name__)
PLATFORMS = [Platform.SENSOR]
SIGNAL_UPDATE = f"{DOMAIN}_update"


@dataclass
class Tracker:
    id: str
    name: str
    find_my_entity: str | None
    keys: TrackerKeys
    estimator: RoomEstimator
    estimate: Estimate | None = None


@dataclass
class Runtime:
    settings: dict
    rooms_by_source: dict[str, str]
    rooms_by_name: dict[str, str]
    trackers: list[Tracker] = field(default_factory=list)


def _load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    path = hass.config.path(CONFIG_FILE)
    try:
        cfg = await hass.async_add_executor_job(_load_config, path)
    except (OSError, ValueError) as err:
        raise ConfigEntryNotReady(f"Cannot read {path}: {err}") from err

    settings = {**DEFAULT_SETTINGS, **cfg.get("settings", {})}
    rt = Runtime(
        settings=settings,
        rooms_by_source={k.upper(): v for k, v in cfg.get("rooms_by_source", {}).items()},
        rooms_by_name=cfg.get("rooms_by_name", {}),
    )
    for t in cfg["trackers"]:
        rt.trackers.append(
            Tracker(
                id=t["id"],
                name=t["name"],
                find_my_entity=t.get("find_my_entity"),
                keys=TrackerKeys.from_base64(t["keys"]),
                estimator=RoomEstimator(settings),
            )
        )
    entry.runtime_data = rt

    @callback
    def _poll(_now=None) -> None:
        now = bluetooth.MONOTONIC_TIME()
        room_of: dict[str, str] = {}
        timestamps: dict[str, dict[str, float]] = {}  # built once per scanner per poll
        for tr in rt.trackers:
            for address in tr.keys.by_address:
                for dev in bluetooth.async_scanner_devices_by_address(hass, address, connectable=False):
                    scanner = dev.scanner
                    source = scanner.source.upper()
                    payload = dev.advertisement.manufacturer_data.get(APPLE_COMPANY_ID)
                    if not tr.keys.matches(address, payload):
                        continue
                    if source not in timestamps:
                        timestamps[source] = scanner.discovered_device_timestamps
                    ts = timestamps[source].get(address) or timestamps[source].get(address.upper())
                    if ts is None:
                        continue
                    tr.estimator.add(source, address, ts, dev.advertisement.rssi, payload)
                    room_of[source] = _room_name(rt, source, scanner.name)
            # Keep names for sources heard earlier but not in this poll.
            for source in tr.estimator.sources():
                room_of.setdefault(source, _room_name(rt, source, None))
            tr.estimate = tr.estimator.evaluate(now, room_of)
        async_dispatcher_send(hass, f"{SIGNAL_UPDATE}_{entry.entry_id}")

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_on_unload(
        async_track_time_interval(hass, _poll, timedelta(seconds=settings["poll_seconds"]))
    )
    _poll()
    return True


def _room_name(rt: Runtime, source: str, scanner_name: str | None) -> str:
    """Friendly room label for a proxy: by BLE MAC, then by ESPHome name."""
    if source in rt.rooms_by_source:
        return rt.rooms_by_source[source]
    if scanner_name:
        base = scanner_name.split(" (")[0]
        # Remember it, so the label stays stable when the proxy is quiet.
        rt.rooms_by_source[source] = rt.rooms_by_name.get(base, base)
        return rt.rooms_by_source[source]
    return source


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
