"""MQTT 5 subscription to device telemetry and status (docs/PLAN.md §4, §5.4).

The gateway connects with a clean start and a session expiry of 0, so the broker keeps no queue
for it while it is disconnected. Mosquitto does not tell a subscriber when a queued message was
published, so replaying such a queue would stamp old readings with the reconnect time. Readings
published while the gateway is away are dropped instead, just as the ESP32 drops readings while
the broker is unreachable. Retained status messages are still delivered on every (re)subscribe.

Messages are acknowledged by hand, only after the handler has committed them. If intake keeps
failing (SQLite locked, disk full) the message is left unacknowledged and the connection is
dropped and reopened, so the broker never records a reading as delivered that was not stored.
"""

from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from typing import Final

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties
from paho.mqtt.reasoncodes import ReasonCode
from paho.mqtt.subscribeoptions import SubscribeOptions

log = logging.getLogger(__name__)

CLIENT_ID: Final = "olvar-gateway"
TELEMETRY_FILTER: Final = "olvar/v1/+/telemetry"
STATUS_FILTER: Final = "olvar/v1/+/status"
KEEPALIVE_S: Final = 60
RECONNECT_MIN_S: Final = 1
RECONNECT_MAX_S: Final = 60
INTAKE_ATTEMPTS: Final = 3
INTAKE_RETRY_S: Final = 0.2

# (topic, payload, retained) — retained is True for a retained message replayed on subscribe.
MessageHandler = Callable[[str, bytes, bool], None]


class MqttClient:
    def __init__(
        self,
        host: str,
        port: int,
        username: str,
        password: str,
        on_message: MessageHandler,
        *,
        client_id: str = CLIENT_ID,
    ) -> None:
        self._host = host
        self._port = port
        self._handler = on_message
        self.connected = threading.Event()
        self._lifecycle = threading.Lock()
        self._stopping = False
        self.intake_failures = 0
        self._client = mqtt.Client(
            callback_api_version=CallbackAPIVersion.VERSION2,
            client_id=client_id,
            protocol=mqtt.MQTTv5,
            manual_ack=True,
        )
        self._client.username_pw_set(username, password)
        self._client.reconnect_delay_set(RECONNECT_MIN_S, RECONNECT_MAX_S)
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.on_message = self._on_message

    def start(self) -> None:
        """Connect in the background; paho keeps reconnecting until `stop`."""
        with self._lifecycle:
            self._stopping = False
            self._connect()

    def _connect(self) -> None:
        properties = Properties(PacketTypes.CONNECT)
        properties.SessionExpiryInterval = 0
        self._client.connect_async(
            self._host,
            self._port,
            keepalive=KEEPALIVE_S,
            clean_start=True,
            properties=properties,
        )
        self._client.loop_start()

    def stop(self) -> None:
        with self._lifecycle:
            self._stopping = True
            self._client.disconnect()
            self._client.loop_stop()
            self.connected.clear()

    def _schedule_reconnect(self) -> None:
        # paho's loop cannot be restarted from its own thread, and a user disconnect ends it.
        threading.Thread(target=self._reconnect, name="mqtt-reconnect", daemon=True).start()

    def _reconnect(self) -> None:
        with self._lifecycle:
            if self._stopping:
                return
            self._client.loop_stop()
            self._connect()

    def _on_connect(
        self,
        client: mqtt.Client,
        userdata: object,
        flags: mqtt.ConnectFlags,
        reason_code: ReasonCode,
        properties: Properties | None,
    ) -> None:
        if reason_code.is_failure:
            log.error("mqtt connect refused: %s", reason_code)
            return
        log.info("mqtt connected to %s:%d", self._host, self._port)
        options = SubscribeOptions(qos=1)
        client.subscribe([(TELEMETRY_FILTER, options), (STATUS_FILTER, options)])
        self.connected.set()

    def _on_disconnect(
        self,
        client: mqtt.Client,
        userdata: object,
        flags: mqtt.DisconnectFlags,
        reason_code: ReasonCode,
        properties: Properties | None,
    ) -> None:
        self.connected.clear()
        if reason_code.is_failure:
            log.warning("mqtt disconnected: %s; reconnecting", reason_code)

    def _on_message(self, client: mqtt.Client, userdata: object, msg: mqtt.MQTTMessage) -> None:
        # An exception escaping a paho callback stops the network thread, and with it all intake.
        for attempt in range(1, INTAKE_ATTEMPTS + 1):
            try:
                self._handler(msg.topic, msg.payload, bool(msg.retain))
            except Exception:
                log.exception(
                    "intake failed for %s (attempt %d/%d)", msg.topic, attempt, INTAKE_ATTEMPTS
                )
                if attempt < INTAKE_ATTEMPTS and not self._stopping:
                    time.sleep(INTAKE_RETRY_S)
                    continue
                break
            client.ack(msg.mid, msg.qos)
            return
        self.intake_failures += 1
        log.error("message on %s not acknowledged; reconnecting", msg.topic)
        client.disconnect()
        self._schedule_reconnect()
