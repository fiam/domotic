#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""
Tiny fake Z-Stack (ZNP) adapter that speaks just enough of the Monitor/Test
protocol for zigbee-herdsman / zigbee2mqtt to come online. The emulator keeps a
very small in-memory NV store, acknowledges the setup sequence, and immediately
reports the coordinator as ready while never emitting any real Zigbee traffic.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import signal
import struct
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

SOF = 0xFE


class MsgType:
    POLL = 0x00
    SREQ = 0x01
    AREQ = 0x02
    SRSP = 0x03


class Subsystem:
    SYS = 0x01
    MAC = 0x02
    NWK = 0x03
    AF = 0x04
    ZDO = 0x05
    SAPI = 0x06
    UTIL = 0x07


class Status:
    SUCCESS = 0x00
    FAILURE = 0x01
    INVALID_PARAM = 0x02
    NV_ITEM_INITIALIZED = 0x09
    NV_ITEM_UNINIT = 0x0B


def build_cmd0(msg_type: int, subsystem: int) -> int:
    return ((msg_type & 0x07) << 5) | (subsystem & 0x1F)


def calc_fcs(data: bytes) -> int:
    xor = 0
    for byte in data:
        xor ^= byte
    return xor


@dataclass
class Frame:
    cmd0: int
    cmd1: int
    payload: bytes


class DevStates:
    HOLD = 0x00
    COORD_STARTING = 0x08
    ZB_COORD = 0x09


class NvId:
    EXTADDR = 0x0001
    NWK_ADDR = 0x0022
    NIB = 0x0021
    EXTENDED_PAN_ID = 0x002D
    NWK_ACTIVE_KEY_INFO = 0x003A
    NWK_ALTERN_KEY_INFO = 0x003B
    PANID = 0x0083
    CHANLIST = 0x0084
    LOGICAL_TYPE = 0x0087
    PRECFGKEY = 0x0062
    NWKKEY = 0x0082
    ZNP_HAS_CONFIGURED_ZSTACK1 = 0x0F00
    ZNP_HAS_CONFIGURED_ZSTACK3 = 0x0060
    SAS_SHORT_ADDR = 0x00B1


EXT_ADDR_BYTES = bytes.fromhex("00124b0001999999")

DEFAULT_NV = {
    NvId.EXTADDR: EXT_ADDR_BYTES[::-1],
    NvId.NWK_ADDR: struct.pack("<H", 0x0000),
    NvId.NIB: bytes(110),
    NvId.EXTENDED_PAN_ID: EXT_ADDR_BYTES,
    NvId.PANID: struct.pack("<H", 0x1A63),
    NvId.CHANLIST: struct.pack("<I", 0x07FFF800),
    NvId.LOGICAL_TYPE: bytes([0x02]),
    NvId.PRECFGKEY: bytes.fromhex("00112233445566778899AABBCCDDEEFF"),
    NvId.NWKKEY: bytes(21),
    NvId.NWK_ACTIVE_KEY_INFO: bytes([0x00]) + bytes(16),
    NvId.NWK_ALTERN_KEY_INFO: bytes([0x00]) + bytes(16),
    NvId.ZNP_HAS_CONFIGURED_ZSTACK1: bytes([0x55]),
    NvId.ZNP_HAS_CONFIGURED_ZSTACK3: bytes([0x55]),
    NvId.SAS_SHORT_ADDR: struct.pack("<H", 0x0000),
}

MAX_NV_CHUNK = 240

NV_LENGTH_HINTS: Dict[int, int] = {
    NvId.NIB: 110,
    NvId.NWK_ADDR: 2,
    NvId.EXTADDR: 8,
    NvId.EXTENDED_PAN_ID: 8,
    NvId.PANID: 2,
    NvId.CHANLIST: 4,
    NvId.LOGICAL_TYPE: 1,
    NvId.PRECFGKEY: 16,
    NvId.NWKKEY: 21,
    NvId.NWK_ACTIVE_KEY_INFO: 17,
    NvId.NWK_ALTERN_KEY_INFO: 17,
    NvId.ZNP_HAS_CONFIGURED_ZSTACK1: 1,
    NvId.ZNP_HAS_CONFIGURED_ZSTACK3: 1,
    NvId.SAS_SHORT_ADDR: 2,
}


class FakeZStack:
    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port
        self._server: Optional[asyncio.AbstractServer] = None
        self._logger = logging.getLogger("fake_zstack")
        self._ext_addr = EXT_ADDR_BYTES
        self._nv: Dict[int, bytearray] = {
            nv_id: bytearray(value) for nv_id, value in DEFAULT_NV.items()
        }
        self._device_state = DevStates.HOLD
        self._short_addr = int.from_bytes(DEFAULT_NV[NvId.NWK_ADDR], "little")
        for nv_id, length in NV_LENGTH_HINTS.items():
            self._nv.setdefault(nv_id, bytearray(length))
        self._pan_id = int.from_bytes(self._nv[NvId.PANID][:2], "little")
        self._channel_mask = int.from_bytes(self._nv[NvId.CHANLIST][:4], "little")
        self._logical_channel = self._derive_channel(self._channel_mask)
        self._extended_pan_id = bytes(self._nv[NvId.EXTENDED_PAN_ID][:8])
        self._network_key = bytes(self._nv[NvId.NWKKEY][:16])
        self._refresh_nib()

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._handle_client, self.host, self.port)
        addr = ", ".join(str(sock.getsockname()) for sock in self._server.sockets or [])
        self._logger.info("Fake Z-Stack adapter listening on %s", addr)

    async def close(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = writer.get_extra_info("peername")
        self._logger.info("Client connected from %s", peer)
        await self._send_frame(
            writer,
            build_cmd0(MsgType.AREQ, Subsystem.SYS),
            0x80,
            bytes([0x00, 0x02, 0x02, 0x02, 0x07, 0x01]),
        )
        try:
            while True:
                frame = await self._read_frame(reader)
                if frame is None:
                    break
                await self._dispatch(frame, writer)
        except asyncio.IncompleteReadError:
            pass
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            self._logger.info("Client %s disconnected", peer)

    async def _dispatch(self, frame: Frame, writer: asyncio.StreamWriter) -> None:
        msg_type = (frame.cmd0 >> 5) & 0x07
        subsystem = frame.cmd0 & 0x1F
        expects_response = msg_type == MsgType.SREQ

        subsystem_names = {1: "SYS", 2: "MAC", 3: "NWK", 4: "AF", 5: "ZDO", 6: "SAPI", 7: "UTIL"}
        msg_type_names = {0: "POLL", 1: "SREQ", 2: "AREQ", 3: "SRSP"}
        self._logger.debug(
            "RX: %s:%s cmd1=0x%02x payload=%s",
            subsystem_names.get(subsystem, f"SUB{subsystem}"),
            msg_type_names.get(msg_type, f"TYPE{msg_type}"),
            frame.cmd1,
            frame.payload.hex()
        )

        handler = {
            Subsystem.SYS: self._handle_sys,
            Subsystem.UTIL: self._handle_util,
            Subsystem.ZDO: self._handle_zdo,
            Subsystem.AF: self._handle_af,
            Subsystem.SAPI: self._handle_sapi,
        }.get(subsystem)

        if handler is None:
            self._logger.warning("No handler for subsystem %d", subsystem)
            if expects_response:
                await self._send_srsp(writer, subsystem, frame.cmd1, bytes([Status.SUCCESS]))
            return

        payloads, async_frames = handler(frame.cmd1, frame.payload)
        if expects_response:
            for payload in payloads:
                await self._send_srsp(writer, subsystem, frame.cmd1, payload)
        for areq in async_frames:
            self._logger.debug(
                "TX AREQ: %s cmd1=0x%02x payload=%s",
                subsystem_names.get(areq.cmd0 & 0x1F, f"SUB{areq.cmd0 & 0x1F}"),
                areq.cmd1,
                areq.payload.hex()
            )
            await self._send_frame(writer, areq.cmd0, areq.cmd1, areq.payload)

    async def _send_srsp(
        self, writer: asyncio.StreamWriter, subsystem: int, cmd1: int, payload: bytes
    ) -> None:
        await self._send_frame(writer, build_cmd0(MsgType.SRSP, subsystem), cmd1, payload)

    def _handle_sys(self, cmd1: int, payload: bytes) -> Tuple[List[bytes], List[Frame]]:
        if cmd1 == 0x00:  # SYS_RESET_REQ
            self._device_state = DevStates.COORD_STARTING
            reason = payload[0] if payload else 0x00
            frame = Frame(
                build_cmd0(MsgType.AREQ, Subsystem.SYS),
                0x80,
                bytes([reason, 0x02, 0x02, 0x02, 0x07, 0x01]),
            )
            return [], [frame]
        if cmd1 == 0x01:  # SYS_PING
            return [struct.pack("<H", 0x0003)], []
        if cmd1 == 0x02:  # SYS_VERSION
            version = bytes([0x02, 0x00, 0x02, 0x00, 0x00]) + struct.pack("<I", 0)
            return [version], []
        if cmd1 == 0x04:  # SYS_SET_EXTADDR
            if len(payload) == 8:
                self._ext_addr = payload
                self._nv[NvId.EXTADDR] = bytearray(payload[::-1])
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x05:  # SYS_GET_EXTADDR
            return [self._ext_addr], []
        if cmd1 == 0x07:  # SYS_OSAL_NV_ITEM_INIT
            if len(payload) < 5:
                return [bytes([Status.INVALID_PARAM])], []
            nv_id, length = struct.unpack_from("<HH", payload, 0)
            init_len = payload[4]
            init_value = payload[5 : 5 + init_len]
            current = self._nv.get(nv_id)
            if current is not None and len(current) == length:
                status = Status.NV_ITEM_INITIALIZED
            else:
                buf = bytearray(length)
                copy_len = min(len(init_value), length)
                buf[:copy_len] = init_value[:copy_len]
                self._nv[nv_id] = buf
                status = Status.NV_ITEM_INITIALIZED
            return [bytes([status])], []
        if cmd1 == 0x08:  # SYS_OSAL_NV_READ
            if len(payload) < 3:
                return [bytes([Status.INVALID_PARAM, 0])], []
            nv_id = struct.unpack_from("<H", payload, 0)[0]
            self._ensure_nv_item(nv_id)
            offset = payload[2]
            req_len = payload[3] if len(payload) > 3 else MAX_NV_CHUNK
            data = self._read_nv(nv_id, offset, min(req_len, MAX_NV_CHUNK))
            if data is None:
                return [bytes([Status.NV_ITEM_UNINIT, 0])], []
            chunk = data[: min(len(data), MAX_NV_CHUNK)]
            return [bytes([Status.SUCCESS, len(chunk)]) + chunk], []
        if cmd1 == 0x09:  # SYS_OSAL_NV_WRITE
            if len(payload) < 4:
                return [bytes([Status.INVALID_PARAM])], []
            nv_id = struct.unpack_from("<H", payload, 0)[0]
            offset = payload[2]
            data_len = payload[3]
            value = payload[4 : 4 + data_len]
            self._write_nv(nv_id, offset, value)
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x0B or cmd1 == 0x13:  # SYS_OSAL_NV_LENGTH
            if len(payload) < 2:
                return [struct.pack("<H", 0)], []
            (nv_id,) = struct.unpack_from("<H", payload, 0)
            self._ensure_nv_item(nv_id)
            length = len(self._nv.get(nv_id, bytearray()))
            return [struct.pack("<H", length)], []
        if cmd1 == 0x0C:  # SYS_SET_TX_POWER
            level = payload[0] if payload else 0
            return [bytes([level])], []
        if cmd1 == 0x0F:  # SYS_STACK_TUNE
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x12:  # SYS_OSAL_NV_COMPARE
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x18:  # SYS_OSAL_NV_DELETE
            if len(payload) < 4:
                return [bytes([Status.INVALID_PARAM])], []
            nv_id, _length = struct.unpack_from("<HH", payload, 0)
            self._nv.pop(nv_id, None)
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x1C:  # SYS_OSAL_NV_READ_EXT
            if len(payload) < 4:
                return [bytes([Status.INVALID_PARAM, 0])], []
            nv_id, offset = struct.unpack_from("<HH", payload, 0)
            self._ensure_nv_item(nv_id)
            data = self._read_nv(nv_id, offset, None)
            if data is None:
                return [bytes([Status.NV_ITEM_UNINIT, 0])], []
            if not data:
                return [bytes([Status.SUCCESS, 0])], []
            chunk = data[: MAX_NV_CHUNK]
            return [bytes([Status.SUCCESS, len(chunk)]) + chunk], []
        if cmd1 == 0x1D:  # SYS_OSAL_NV_WRITE_EXT
            if len(payload) < 6:
                return [bytes([Status.INVALID_PARAM])], []
            nv_id, offset, data_len = struct.unpack_from("<HHH", payload, 0)
            value = payload[6 : 6 + data_len]
            self._write_nv(nv_id, offset, value)
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x20:  # SYS_SET_TX_POWER alias
            return [bytes([Status.SUCCESS])], []
        return [bytes([Status.SUCCESS])], []

    def _handle_util(self, cmd1: int, payload: bytes) -> Tuple[List[bytes], List[Frame]]:
        if cmd1 == 0x00:  # UTIL_GET_DEVICE_INFO
            ieee = self._ext_addr[::-1]
            short_addr = struct.pack("<H", self._short_addr)
            response = (
                bytes([Status.SUCCESS])
                + ieee
                + short_addr
                + bytes([0x02])  # coordinator
                + bytes([self._device_state])
                + bytes([0x00])  # num assoc devices
            )
            return [response], []
        if cmd1 == 0x01:  # UTIL_GET_NV_INFO
            ieee = self._ext_addr[::-1]
            channels = bytes(self._nv.get(NvId.CHANLIST, bytearray(struct.pack("<I", 0x07FFF800))))
            panid = bytes(self._nv.get(NvId.PANID, bytearray(struct.pack("<H", 0x1A63))))
            key = bytes(self._nv.get(NvId.PRECFGKEY, bytearray(16)))
            response = bytes([Status.SUCCESS]) + ieee + channels[:4].ljust(4, b"\x00") + panid[:2].ljust(2, b"\x00") + bytes([0x05]) + key[:16].ljust(16, b"\x00")
            return [response], []
        if cmd1 == 0x02:  # UTIL_SET_PANID
            if len(payload) == 2:
                self._nv[NvId.PANID] = bytearray(payload)
                self._pan_id = int.from_bytes(payload, "little")
                self._refresh_nib()
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x03:  # UTIL_SET_CHANNELS
            if len(payload) == 4:
                self._nv[NvId.CHANLIST] = bytearray(payload)
                self._channel_mask = int.from_bytes(payload, "little")
                self._logical_channel = self._derive_channel(self._channel_mask)
                self._refresh_nib()
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x04:  # UTIL_SET_SECLEVEL
            if payload:
                self._nv[0x0061] = bytearray(payload[:1])
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x05:  # UTIL_SET_PRECFGKEY
            if payload:
                self._nv[NvId.PRECFGKEY] = bytearray(payload[:16])
                self._network_key = bytes(self._nv[NvId.PRECFGKEY][:16])
                self._refresh_nib()
            return [bytes([Status.SUCCESS])], []
        if cmd1 == 0x09:  # UTIL_CALLBACK_SUBCMD (ignored)
            return [bytes([Status.SUCCESS])], []
        return [bytes([Status.SUCCESS])], []

    def _handle_af(self, cmd1: int, payload: bytes) -> Tuple[List[bytes], List[Frame]]:
        if cmd1 == 0x00:  # AF_REGISTER
            return [bytes([Status.SUCCESS])], []
        if cmd1 in (0x01, 0x02, 0x03):  # DATA_REQUEST variants
            confirm = self._build_af_confirm(cmd1, payload)
            frames = []
            if confirm is not None:
                frames.append(Frame(build_cmd0(MsgType.AREQ, Subsystem.AF), 0x80, confirm))
            return [bytes([Status.SUCCESS])], frames
        return [bytes([Status.SUCCESS])], []

    def _build_af_confirm(self, cmd1: int, payload: bytes) -> Optional[bytes]:
        try:
            if cmd1 == 0x01 and len(payload) >= 9:
                srcendpoint = payload[3]
                transid = payload[6]
            elif cmd1 == 0x02 and len(payload) >= 17:
                srcendpoint = payload[13]
                transid = payload[16]
            elif cmd1 == 0x03 and len(payload) >= 10:
                srcendpoint = payload[3]
                transid = payload[6]
            else:
                return None
        except IndexError:
            return None
        return bytes([Status.SUCCESS, srcendpoint, transid])

    def _handle_sapi(self, cmd1: int, payload: bytes) -> Tuple[List[bytes], List[Frame]]:
        if cmd1 == 0x04:  # READ_CONFIGURATION
            if not payload:
                return [bytes([Status.INVALID_PARAM, 0, 0])], []
            config_id = payload[0]
            value = bytes(self._nv.get(config_id, bytearray()))
            value = value[: min(len(value), 0xFF)]
            response = bytes([Status.SUCCESS, config_id, len(value)]) + value
            return [response], []
        if cmd1 == 0x05:  # WRITE_CONFIGURATION
            if len(payload) < 2:
                return [bytes([Status.INVALID_PARAM])], []
            config_id = payload[0]
            length = payload[1]
            value = payload[2 : 2 + length]
            self._nv[config_id] = bytearray(value)
            if config_id in (NvId.NWK_ADDR, NvId.SAS_SHORT_ADDR) and len(value) >= 2:
                self._short_addr = int.from_bytes(value[:2], "little")
            return [bytes([Status.SUCCESS])], []
        return [bytes([Status.SUCCESS])], []

    def _handle_zdo(self, cmd1: int, payload: bytes) -> Tuple[List[bytes], List[Frame]]:
        if cmd1 == 0x40:  # ZDO_STARTUP_FROM_APP
            self._device_state = DevStates.ZB_COORD
            self._refresh_nib()
            areq = Frame(build_cmd0(MsgType.AREQ, Subsystem.ZDO), 0xC0, bytes([DevStates.ZB_COORD]))
            return [bytes([Status.SUCCESS])], [areq]
        if cmd1 == 0x50:  # ZDO_EXT_NWK_INFO
            payload = (
                struct.pack("<H", self._short_addr)
                + bytes([self._device_state])
                + struct.pack("<H", self._pan_id)
                + struct.pack("<H", 0x0000)
                + self._extended_pan_id[::-1]
                + self._ext_addr[::-1]
                + bytes([self._logical_channel])
            )
            return [payload], []
        if cmd1 == 0x04:  # ZDO_SIMPLE_DESC_REQ
            # Parse: dst_addr (2) + nwk_addr (2) + endpoint (1)
            if len(payload) < 5:
                return [bytes([Status.INVALID_PARAM])], []
            dst_addr, nwk_addr, endpoint = struct.unpack_from("<HHB", payload, 0)
            self._logger.debug("ZDO_SIMPLE_DESC_REQ dst=0x%04x nwk=0x%04x ep=%d", dst_addr, nwk_addr, endpoint)
            # Return SRSP with success
            # Send async AREQ with simple descriptor response (cmd1=0x84)
            # Format: src_addr (2) + status (1) + nwk_addr (2) + len (1) + descriptor
            # Descriptor: endpoint (1) + profile (2) + device_id (2) + device_ver (1) +
            #            in_cluster_count (1) + in_clusters (2*count) +
            #            out_cluster_count (1) + out_clusters (2*count)

            # Build a minimal descriptor for ZDO endpoint
            profile_id = 0x0104  # HA profile
            device_id = 0x0005    # Configuration tool
            device_ver = 0x00

            # Common clusters for coordinator
            in_clusters = [0x0000, 0x0003, 0x0006]  # Basic, Identify, On/Off
            out_clusters = [0x0019]  # OTA Upgrade

            descriptor = (
                bytes([endpoint])
                + struct.pack("<H", profile_id)
                + struct.pack("<H", device_id)
                + bytes([device_ver])
                + bytes([len(in_clusters)])
                + b''.join(struct.pack("<H", c) for c in in_clusters)
                + bytes([len(out_clusters)])
                + b''.join(struct.pack("<H", c) for c in out_clusters)
            )

            areq_payload = (
                struct.pack("<H", nwk_addr)  # source address
                + bytes([Status.SUCCESS])     # status
                + struct.pack("<H", nwk_addr) # network address
                + bytes([len(descriptor)])    # length
                + descriptor
            )
            # Response callback uses 0x80 + request cmd1 = 0x84
            areq = Frame(build_cmd0(MsgType.AREQ, Subsystem.ZDO), 0x84, areq_payload)
            return [bytes([Status.SUCCESS])], [areq]
        if cmd1 == 0x05:  # ZDO_ACTIVE_EP_REQ
            # Parse the request: destination address (2 bytes) + network address of interest (2 bytes)
            if len(payload) < 4:
                return [bytes([Status.INVALID_PARAM])], []
            dst_addr, nwk_addr = struct.unpack_from("<HH", payload, 0)
            self._logger.debug("ZDO_ACTIVE_EP_REQ dst=0x%04x nwk=0x%04x", dst_addr, nwk_addr)
            # Return SRSP with success status
            # Send async AREQ with active endpoint response (0x45)
            # Format: src_addr (2) + status (1) + nwk_addr (2) + count (1) + endpoints[]
            # Coordinator typically has endpoint 1, 2, 11, 110, 242 for various ZDO and Green Power functions
            endpoints = [1, 2, 11, 110, 242]
            areq_payload = (
                struct.pack("<H", nwk_addr)    # source address (responding device)
                + bytes([Status.SUCCESS])       # status
                + struct.pack("<H", nwk_addr)   # network address
                + bytes([len(endpoints)])       # endpoint count
                + bytes(endpoints)              # endpoint list
            )
            # Response callback uses 0x80 + request cmd1 = 0x85
            areq = Frame(build_cmd0(MsgType.AREQ, Subsystem.ZDO), 0x85, areq_payload)
            return [bytes([Status.SUCCESS])], [areq]
        if cmd1 == 0x4A:  # ZDO_EXT_FIND_GROUP
            # Parse: endpoint (1 byte) + group ID (2 bytes)
            if len(payload) < 3:
                return [bytes([Status.INVALID_PARAM, 0x00, 0x00, 0x00])], []
            endpoint = payload[0]
            group_id = struct.unpack_from("<H", payload, 1)[0]
            self._logger.debug("ZDO_EXT_FIND_GROUP endpoint=%d group_id=0x%04x", endpoint, group_id)
            # Response: status (1) + group (2) + name_len (1) [+ name (variable)]
            # Return not found (status=0x01) or found with empty name
            # For now, return SUCCESS with the group and empty name
            response = bytes([Status.SUCCESS]) + struct.pack("<H", group_id) + bytes([0x00])
            return [response], []
        if cmd1 in (0x36, 0x37):  # permit join / leave
            return [bytes([Status.SUCCESS])], []
        return [bytes([Status.SUCCESS])], []

    def _read_nv(self, nv_id: int, offset: int, length: Optional[int]) -> Optional[bytes]:
        data = self._nv.get(nv_id)
        if data is None:
            return None
        if offset >= len(data):
            return b""
        end = len(data) if length is None else min(len(data), offset + length)
        return bytes(data[offset:end])

    def _write_nv(self, nv_id: int, offset: int, value: bytes) -> None:
        if not value:
            return
        needed = offset + len(value)
        buf = self._nv.setdefault(nv_id, bytearray(needed))
        if len(buf) < needed:
            buf.extend(b"\x00" * (needed - len(buf)))
        buf[offset : offset + len(value)] = value
        if nv_id == NvId.NWK_ADDR and len(buf) >= 2 and offset == 0:
            self._short_addr = int.from_bytes(buf[:2], "little")
        if nv_id == NvId.SAS_SHORT_ADDR and len(buf) >= 2 and offset == 0:
            self._short_addr = int.from_bytes(buf[:2], "little")
        if nv_id == NvId.PANID and offset == 0 and len(buf) >= 2:
            self._pan_id = int.from_bytes(buf[:2], "little")
            self._refresh_nib()
        if nv_id == NvId.CHANLIST and offset == 0 and len(buf) >= 4:
            self._channel_mask = int.from_bytes(buf[:4], "little")
            self._logical_channel = self._derive_channel(self._channel_mask)
            self._refresh_nib()
        if nv_id == NvId.EXTENDED_PAN_ID and offset == 0 and len(buf) >= 8:
            self._extended_pan_id = bytes(buf[:8])
            self._refresh_nib()
        if nv_id == NvId.NWKKEY and offset == 0:
            self._network_key = bytes(buf[:16])
            self._refresh_nib()

    def _derive_channel(self, mask: int) -> int:
        for ch in range(11, 27):
            if mask & (1 << ch):
                return ch
        return 11

    def _refresh_nib(self) -> None:
        buf = self._nv.setdefault(NvId.NIB, bytearray(110))
        buf[:] = b"\x00" * 110
        struct.pack_into("<H", buf, 20, self._short_addr)
        buf[22] = self._logical_channel
        struct.pack_into("<H", buf, 23, 0x0000)
        buf[25:33] = self._ext_addr[::-1]
        struct.pack_into("<H", buf, 33, self._pan_id)
        buf[35] = self._device_state
        struct.pack_into("<I", buf, 36, self._channel_mask & 0xFFFFFFFF)
        buf[53:61] = self._extended_pan_id[::-1]
        buf[61] = 0x01
        buf[62] = 0x00
        buf[63:79] = self._network_key[:16].ljust(16, b"\x00")
        buf[79] = 0x00
        buf[80:96] = self._network_key[:16].ljust(16, b"\x00")
        buf[96] = buf[97] = 0
        buf[98:105] = b"\x00" * 7
        struct.pack_into("<H", buf, 105, 0)
        struct.pack_into("<H", buf, 107, 0)
        buf[109] = 0

    def _ensure_nv_item(self, nv_id: int) -> None:
        if nv_id in self._nv:
            return
        length = NV_LENGTH_HINTS.get(nv_id)
        if length is not None:
            self._nv[nv_id] = bytearray(length)

    async def _read_frame(self, reader: asyncio.StreamReader) -> Optional[Frame]:
        while True:
            sof = await reader.read(1)
            if not sof:
                return None
            if sof[0] == SOF:
                break
        length_bytes = await reader.readexactly(1)
        length = length_bytes[0]
        header = await reader.readexactly(2)
        payload = await reader.readexactly(length)
        fcs = await reader.readexactly(1)
        if calc_fcs(length_bytes + header + payload) != fcs[0]:
            return None
        cmd0, cmd1 = header
        return Frame(cmd0, cmd1, payload)

    async def _send_frame(self, writer: asyncio.StreamWriter, cmd0: int, cmd1: int, payload: bytes) -> None:
        body = bytes([len(payload), cmd0, cmd1]) + payload
        fcs = calc_fcs(body)
        frame = bytes([SOF]) + body + bytes([fcs])
        writer.write(frame)
        await writer.drain()


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6638)
    parser.add_argument("--log-level", default="DEBUG")
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    server = FakeZStack(args.host, args.port)
    await server.start()

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    await server.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
