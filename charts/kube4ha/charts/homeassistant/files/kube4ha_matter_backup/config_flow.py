"""Enable the native Matter backup hook without credentials."""
import voluptuous as vol
from homeassistant import config_entries


class ConfigFlow(config_entries.ConfigFlow, domain="kube4ha_matter_backup"):
    VERSION = 1

    async def async_step_user(self, user_input=None):
        await self.async_set_unique_id("kube4ha_matter_backup")
        self._abort_if_unique_id_configured()
        if user_input is not None:
            return self.async_create_entry(title="kube4ha Matter Backup", data={})
        return self.async_show_form(step_id="user", data_schema=vol.Schema({}))
