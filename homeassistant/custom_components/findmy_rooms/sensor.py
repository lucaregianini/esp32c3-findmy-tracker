"""One "near" sensor per tracker."""

from __future__ import annotations

import time
from datetime import timedelta

from homeassistant.components.sensor import SensorEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.util import dt as dt_util

from . import SIGNAL_UPDATE, Tracker
from .const import DOMAIN

# Find My fallback wording when no hub has heard the tracker recently.
FALLBACK = {"home": "Home", "not_home": "Away"}


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    rt = entry.runtime_data
    async_add_entities(NearSensor(entry, tr) for tr in rt.trackers)


class NearSensor(SensorEntity):
    """e.g. sensor.c3tracker_near = "Near Kitchen" (shown as "C3 Tracker location")."""

    _attr_should_poll = False
    _attr_icon = "mdi:map-marker-radius"
    # These change every few seconds; keep them out of the history database.
    _unrecorded_attributes = frozenset({"rssi", "seconds_since_seen", "margin_db", "address"})

    def __init__(self, entry: ConfigEntry, tracker: Tracker) -> None:
        self._entry = entry
        self._tr = tracker
        self._attr_unique_id = f"{DOMAIN}_{tracker.id}"
        # "location", not "near": the fallback state is "Home"/"Away".
        self._attr_name = f"{tracker.name} location"
        self.entity_id = f"sensor.{tracker.id}_near"
        self._last_write = 0.0
        self._written = False
        self._last_room: str | None = None

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(
            async_dispatcher_connect(
                self.hass, f"{SIGNAL_UPDATE}_{self._entry.entry_id}", self._handle_update
            )
        )
        self._handle_update()

    def _compute(self) -> tuple[str | None, dict]:
        est = self._tr.estimate
        attrs: dict = {"find_my_entity": self._tr.find_my_entity}
        if est is not None:
            attrs.update(
                rssi=est.rssi_by_room,
                seconds_since_seen=est.seconds_since_seen,
                margin_db=est.margin_db,
                battery=est.battery,
                address=est.address,
            )
            if est.seconds_since_seen is not None:
                attrs["last_seen"] = (
                    dt_util.utcnow() - timedelta(seconds=est.seconds_since_seen)
                ).isoformat(timespec="seconds")
        if est is not None and est.room is not None:
            attrs.update(room=est.room, source="bluetooth")
            return f"Near {est.room}", attrs

        attrs.update(room=None, source="find_my")
        fm = self.hass.states.get(self._tr.find_my_entity) if self._tr.find_my_entity else None
        if fm is None or fm.state in ("unknown", "unavailable"):
            return None, attrs
        return FALLBACK.get(fm.state, fm.state), attrs

    @callback
    def _handle_update(self) -> None:
        state, attrs = self._compute()
        now = time.monotonic()
        changed = (
            not self._written
            or state != self._attr_native_value
            or attrs.get("room") != self._last_room
        )
        if not changed and now - self._last_write < self._entry.runtime_data.settings["min_write_seconds"]:
            return  # nothing new worth writing
        self._attr_native_value = state
        self._attr_extra_state_attributes = attrs
        self._last_write = now
        self._last_room = attrs.get("room")
        self._written = True
        self.async_write_ha_state()
