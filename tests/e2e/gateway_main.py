"""Runs the gateway with a chosen clock-sync flag file.

Dev machines and CI runners have no /run/systemd/timesync/synchronized, and without it every row
would wait in the outbox for a clock sync that never comes.
"""

import functools
import os
import sys
from pathlib import Path

from olvar_gateway import __main__, clock, service

service.Clock = functools.partial(clock.Clock, sync_flag=Path(os.environ["E2E_SYNC_FLAG"]))
sys.exit(__main__.main(sys.argv[1:]))
