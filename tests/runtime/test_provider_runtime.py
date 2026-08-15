from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "runtime"))

from aec_runtime.providers import (  # noqa: E402
    ProviderManager,
    classify_access,
    provider_config_path,
)


class ProviderRuntimeTests(unittest.TestCase):
    def test_new_environment_name_wins_while_legacy_name_remains_compatible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            current = Path(temporary) / "current.json"
            legacy = Path(temporary) / "legacy.json"
            with patch.dict(
                os.environ,
                {
                    "BIM_BRIDGE_PROVIDER_CONFIG": str(current),
                    "AEC_CODEX_PROVIDER_CONFIG": str(legacy),
                },
            ):
                self.assertEqual(current, provider_config_path())

    def test_provider_config_and_access_classification_live_in_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "providers.json"
            config.write_text(
                json.dumps(
                    {
                        "providers": [
                            {
                                "id": "test-provider",
                                "enabled": True,
                                "command": "missing-test-provider.exe",
                                "application": "revit",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            with patch.dict(os.environ, {"BIM_BRIDGE_PROVIDER_CONFIG": str(config)}):
                manager = ProviderManager()
                try:
                    listed = manager.list(probe=False)
                    self.assertEqual("test-provider", listed["providers"][0]["id"])
                    self.assertEqual("configured", listed["providers"][0]["status"])
                finally:
                    manager.close()
        self.assertEqual("read", classify_access({"name": "get_elements"}))
        self.assertEqual("write", classify_access({"name": "create_wall"}))

    def test_old_gateway_is_only_a_compatibility_import(self) -> None:
        source = (
            REPOSITORY_ROOT
            / "plugins"
            / "aec-codex"
            / "mcp-server"
            / "provider_gateway.py"
        ).read_text(encoding="utf-8")
        self.assertIn("from aec_runtime.providers import", source)
        self.assertNotIn("class ProviderManager", source)
        self.assertNotIn("subprocess.Popen", source)

    def test_invalid_reload_keeps_previous_provider_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "providers.json"
            config.write_text(
                json.dumps({"providers": [{"id": "stable-provider", "command": sys.executable}]}),
                encoding="utf-8",
            )
            with patch.dict(os.environ, {"BIM_BRIDGE_PROVIDER_CONFIG": str(config)}):
                manager = ProviderManager()
                try:
                    manager.reload(force=True)
                    previous = manager.get("stable-provider")
                    config.write_text("{invalid", encoding="utf-8")
                    manager.reload(force=True)
                    self.assertIs(previous, manager.get("stable-provider"))
                    self.assertIn("Previous provider generation remains active", manager.warnings)
                finally:
                    manager.close()


if __name__ == "__main__":
    unittest.main()
