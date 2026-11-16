from datetime import UTC, datetime, timedelta

from olvar_gateway.clock import Clock, read_boot_id

T0 = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)


class Fake:
    def __init__(self) -> None:
        self.wall = T0
        self.mono = 1_000_000_000

    def advance(self, seconds: float) -> None:
        self.wall += timedelta(seconds=seconds)
        self.mono += int(seconds * 1e9)


def make(tmp_path, fake: Fake, boot_id: str = "boot-a") -> Clock:
    return Clock(
        sync_flag=tmp_path / "synchronized",
        boot_id=boot_id,
        wall=lambda: fake.wall,
        mono_ns=lambda: fake.mono,
    )


def test_unsynced_until_flag_exists(tmp_path):
    fake = Fake()
    clock = make(tmp_path, fake)
    stamp = clock.now()
    assert not stamp.synced
    assert stamp.wall == T0  # best-effort wall is kept for the 'unsynced' fallback
    assert stamp.mono_ns == fake.mono
    assert stamp.pi_boot_id == "boot-a"

    (tmp_path / "synchronized").touch()
    assert clock.now().synced


def test_backfill_same_boot_after_sync(tmp_path):
    fake = Fake()
    clock = make(tmp_path, fake)
    held = clock.now()
    assert clock.backfill(held.mono_ns, held.pi_boot_id) is None  # not synced yet

    fake.advance(90)
    fake.wall = datetime(2026, 11, 20, 8, 0, tzinfo=UTC)  # NTP corrects the wall clock
    (tmp_path / "synchronized").touch()
    assert clock.backfill(held.mono_ns, held.pi_boot_id) == fake.wall - timedelta(seconds=90)


def test_backfill_refuses_other_boot(tmp_path):
    fake = Fake()
    clock = make(tmp_path, fake)
    (tmp_path / "synchronized").touch()
    assert clock.backfill(fake.mono, "boot-b") is None


def test_read_boot_id(tmp_path):
    path = tmp_path / "boot_id"
    path.write_text("5c1e0d8e-1111-4222-8333-944455556666\n")
    assert read_boot_id(path) == "5c1e0d8e-1111-4222-8333-944455556666"
    fallback = read_boot_id(tmp_path / "missing")
    assert fallback.startswith("proc-")
