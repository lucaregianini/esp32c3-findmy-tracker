"""Room estimation for DIY Find My trackers (no Home Assistant imports).

Each tracker rotates through 12 public advertisement keys (28 bytes each).
Over the air a key shows up as:
  BLE address       = key[0] | 0xC0, key[1..5]
  Apple mfr payload = 0x12 0x19 <status> key[6..27] <key[0] >> 6> 0x00
so a tracker is recognised from its public keys alone.

For every proxy (room hub) we keep recent RSSI samples per tracker, take the
median over a short window, and pick the strongest room. Big hallways make
RSSI noisy, so switching rooms needs a clear margin held for a while.
"""

from __future__ import annotations

import base64
from collections import deque
from dataclasses import dataclass, field
from statistics import median

from .const import BATTERY_LEVELS, OFFLINE_FINDING_PREFIX


def key_to_address(key: bytes) -> str:
    """Return the BLE random static address for a 28-byte public key."""
    addr = bytes([key[0] | 0xC0]) + key[1:6]
    return ":".join(f"{b:02X}" for b in addr)


@dataclass
class TrackerKeys:
    """Address -> expected payload tail for one tracker's keys."""

    by_address: dict[str, bytes] = field(default_factory=dict)

    @classmethod
    def from_base64(cls, keys: list[str]) -> TrackerKeys:
        out = cls()
        for k in keys:
            raw = base64.b64decode(k)
            if len(raw) != 28:
                raise ValueError(f"public key must be 28 bytes, got {len(raw)}")
            out.by_address[key_to_address(raw)] = raw[6:28]
        return out

    def matches(self, address: str, payload: bytes | None) -> bool:
        """True if payload is this tracker's advertisement for address."""
        tail = self.by_address.get(address.upper())
        return (
            tail is not None
            and payload is not None
            and len(payload) >= 25
            and payload[:2] == OFFLINE_FINDING_PREFIX
            and payload[3:25] == tail
        )


@dataclass
class Estimate:
    """Result of one evaluation for a tracker."""

    room: str | None  # None -> not heard recently, use Find My fallback
    rssi_by_room: dict[str, float]
    seconds_since_seen: float | None
    margin_db: float | None
    battery: str | None
    address: str | None


class RoomEstimator:
    """Smoothed, hysteretic nearest-room estimate for one tracker."""

    def __init__(self, settings: dict) -> None:
        self.s = settings
        # source -> deque[(monotonic_ts, rssi)]
        self._samples: dict[str, deque[tuple[float, int]]] = {}
        self._last_ts: dict[tuple[str, str], float] = {}  # (source, addr) -> ts
        self._last_seen: float | None = None
        self._battery: str | None = None
        self._address: str | None = None
        self.room: str | None = None
        self._challenger: str | None = None
        self._challenger_since: float | None = None

    def add(self, source: str, address: str, ts: float, rssi: int, payload: bytes) -> None:
        """Record one advertisement seen by a proxy (duplicates are ignored)."""
        key = (source, address)
        if self._last_ts.get(key) == ts:
            return  # same advertisement as last poll
        self._last_ts[key] = ts
        self._samples.setdefault(source, deque()).append((ts, rssi))
        if self._last_seen is None or ts > self._last_seen:
            self._last_seen = ts
            self._address = address
            self._battery = BATTERY_LEVELS.get(payload[2] & 0xC0)

    def sources(self) -> list[str]:
        """Proxies that have heard this tracker recently."""
        return list(self._samples)

    def evaluate(self, now: float, room_of: dict[str, str]) -> Estimate:
        """Update and return the estimate. room_of maps proxy source -> room."""
        window = self.s["window_seconds"]
        by_room: dict[str, float] = {}
        for source, dq in self._samples.items():
            while dq and now - dq[0][0] > window:
                dq.popleft()
            if dq:
                room = room_of.get(source, source)
                # Per-room correction for hubs that hear unusually well/badly.
                m = median(r for _, r in dq) + self.s["rssi_offsets"].get(room, 0)
                # Two proxies in one room: keep the stronger one.
                by_room[room] = max(m, by_room.get(room, -999))
        self._last_ts = {k: t for k, t in self._last_ts.items() if now - t <= window}

        since = None if self._last_seen is None else now - self._last_seen
        if since is None or since > self.s["lost_after_seconds"]:
            self.room = None
            self._challenger = None
        elif by_room:
            self._choose(now, by_room)
        # else: heard recently but no fresh samples -> hold the current room

        margin = None
        if self.room in by_room and len(by_room) > 1:
            others = [v for r, v in by_room.items() if r != self.room]
            margin = round(by_room[self.room] - max(others), 1)
        return Estimate(
            room=self.room,
            rssi_by_room={r: round(v, 1) for r, v in sorted(by_room.items(), key=lambda x: -x[1])},
            seconds_since_seen=None if since is None else round(since, 1),
            margin_db=margin,
            battery=self._battery,
            address=self._address,
        )

    def _choose(self, now: float, by_room: dict[str, float]) -> None:
        best = max(by_room, key=by_room.get)
        if self.room is None or self.room not in by_room:
            # Nothing to hold on to: take the best room straight away.
            self.room, self._challenger = best, None
            return
        if best == self.room or by_room[best] < by_room[self.room] + self.s["switch_margin_db"]:
            self._challenger = None
            return
        if self._challenger != best:
            self._challenger, self._challenger_since = best, now
        elif now - self._challenger_since >= self.s["switch_confirm_seconds"]:
            self.room, self._challenger = best, None
