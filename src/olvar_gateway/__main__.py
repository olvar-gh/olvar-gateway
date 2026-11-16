"""`python -m olvar_gateway [run | status] [--check-config]`."""

from __future__ import annotations

import argparse
import json
import logging
import signal
import sys
import threading
from collections.abc import Sequence
from types import FrameType

from . import config as config_mod
from . import log as log_mod
from .buffer import Outbox
from .service import build

log = logging.getLogger("olvar_gateway")


def _check_config() -> int:
    try:
        cfg = config_mod.load()
    except config_mod.ConfigError as exc:
        print(exc, file=sys.stderr)
        return 2
    print(json.dumps(cfg.redacted(), indent=2))
    print("config ok")
    return 0


def _status() -> int:
    path = config_mod.outbox_path()
    if not path.exists():
        print(f"no outbox at {path} (set OUTBOX_PATH)", file=sys.stderr)
        return 1
    outbox = Outbox(path)
    try:
        print(f"outbox: {path}")
        print(f"queue_depth: {outbox.depth()}")
        print(f"dead_letters: {outbox.dead_letter_count()}")
        print(f"last_error: {outbox.last_error() or 'none'}")
    finally:
        outbox.close()
    return 0


def _run() -> int:
    try:
        cfg = config_mod.load()
    except config_mod.ConfigError as exc:
        print(exc, file=sys.stderr)
        return 2
    log_mod.setup(cfg.log_level)
    service = build(cfg)
    stop = threading.Event()

    def on_signal(signum: int, frame: FrameType | None) -> None:
        log.info("received %s, shutting down", signal.Signals(signum).name)
        stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    service.start()
    while not stop.wait(1.0):
        pass
    service.stop()
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="olvar-gateway", description=__doc__)
    parser.add_argument("command", nargs="?", choices=("run", "status"), default="run")
    parser.add_argument(
        "--check-config", action="store_true", help="validate the environment and exit"
    )
    args = parser.parse_args(argv)
    if args.check_config:
        return _check_config()
    if args.command == "status":
        return _status()
    return _run()


if __name__ == "__main__":
    sys.exit(main())
