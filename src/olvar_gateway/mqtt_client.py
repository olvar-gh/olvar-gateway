"""MQTT 5 subscription to device telemetry and status (docs/PLAN.md §4, §5.4).

The gateway connects with a clean start and a session expiry of 0, so the broker keeps no queue
for it while it is disconnected. Mosquitto does not tell a subscriber when a queued message was
published, so replaying such a queue would stamp old readings with the reconnect time. Readings
published while the gateway is away are dropped instead, just as the ESP32 drops readings while
the broker is unreachable. Retained status messages are still delivered on every (re)subscribe.
"""

from __future__ import annotations

import logging
import threading
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
        self._client = mqtt.Client(
            callback_api_version=CallbackAPIVersion.VERSION2,
            client_id=client_id,
            protocol=mqtt.MQTTv5,
        )
        self._client.username_pw_set(username, password)
        self._client.reconnect_delay_set(RECONNECT_MIN_S, RECONNECT_MAX_S)
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.on_message = self._on_message

    def start(self) -> None:
        """Connect in the background; paho keeps reconnecting until `stop`."""
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
        self._client.disconnect()
        self._client.loop_stop()
        self.connected.clear()

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
        try:
            self._handler(msg.topic, msg.payload, bool(msg.retain))
        except Exception:
            log.exception("failed to handle message on %s", msg.topic)
