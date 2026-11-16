"""Trustworthy time for readings (docs/PLAN.md §2.1, §5.3, §5.4).

The Pi has no RTC. Until systemd-timesyncd has synced once this boot, the wall clock may be the
last saved time, so readings keep only a monotonic stamp plus the Pi's boot id and are backfilled
(`wall - (mono_now - mono_ns)`) once the clock is synced in the same boot.
"""

from __future__ import annotations

import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Final

SYNC_FLAG: Final = Path("/run/systemd/timesync/synchronized")
BOOT_ID_FILE: Final = Path("/proc/sys/kernel/random/boot_id")


@dataclass(frozen=True)
class Stamp:
    wall: datetime | None  # best-effort wall time; trustworthy only when `synced`
    mono_ns: int
    pi_boot_id: str
    synced: bool


def read_boot_id(path: Path = BOOT_ID_FILE) -> str:
    """The kernel's per-boot id. Off Linux (dev machines) a per-process id stands in."""
    try:
        return path.read_text().strip()
    except OSError:
        return f"proc-{uuid.uuid4()}"


class Clock:
    def __init__(
        self,
        *,
        sync_flag: Path = SYNC_FLAG,
        boot_id: str | None = None,
        wall: Callable[[], datetime] = lambda: datetime.now(UTC),
        mono_ns: Callable[[], int] = time.monotonic_ns,
    ) -> None:
        self._sync_flag = sync_flag
        self._boot_id = boot_id if boot_id is not None else read_boot_id()
        self._wall = wall
        self._mono_ns = mono_ns

    @property
    def pi_boot_id(self) -> str:
        return self._boot_id

    def synced(self) -> bool:
        return self._sync_flag.exists()

    def now(self) -> Stamp:
        # Check the flag first: a sync landing mid-sample then yields an unsynced stamp (held
        # and backfilled) instead of pre-correction wall time marked as trusted.
        synced = self.synced()
        mono = self._mono_ns()
        return Stamp(wall=self._wall(), mono_ns=mono, pi_boot_id=self._boot_id, synced=synced)

    def backfill(self, mono_ns: int, pi_boot_id: str) -> datetime | None:
        """Wall time of an earlier monotonic stamp, or None if not synced or from another boot."""
        if pi_boot_id != self._boot_id or not self.synced():
            return None
        mono_now = self._mono_ns()
        return self._wall() - timedelta(microseconds=(mono_now - mono_ns) // 1000)
