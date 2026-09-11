"""Use Home Assistant's documented pre/post-backup platform."""
import os
import aiohttp
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError


async def async_pre_backup(hass: HomeAssistant) -> None:
    if os.environ.get("KUBE4HA_MATTER_BACKUP_ENABLED") != "true":
        return
    if not hass.config_entries.async_loaded_entries("kube4ha_matter_backup"):
        return
    # A failed fresh snapshot aborts the native backup. It must not silently
    # claim to protect current pairings using a previous, potentially stale archive.
    try:
        connector = aiohttp.UnixConnector(path="/run/kube4ha-matter/control.sock")
        # Allow 60s for WebSocket shutdown/storage flush and two 30s archive
        # operations, plus HTTP/IPC overhead.
        async with aiohttp.ClientSession(connector=connector, timeout=aiohttp.ClientTimeout(total=150)) as session:
            async with session.post("http://localhost/snapshot") as response:
                response.raise_for_status()
                result = await response.json()
                if result != {"format": 1}:
                    raise HomeAssistantError("Invalid Matter snapshot response")
    except (aiohttp.ClientError, TimeoutError, OSError) as err:
        raise HomeAssistantError("Could not snapshot Matter state; native backup aborted") from err


async def async_post_backup(hass: HomeAssistant) -> None:
    # The supervisor restarts Matter in a finally block before acknowledging
    # the snapshot, including when the caller disconnects or a backup fails.
    return
