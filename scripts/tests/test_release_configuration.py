import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
import plistlib
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / "validate_release_configuration.py"


class ReleaseConfigurationTests(unittest.TestCase):
    def check(self, configuration="Release", environment="production", url=""):
        spec = importlib.util.spec_from_file_location("release_configuration", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.validate(configuration, environment, url)

    def test_release_requires_formal_configuration(self):
        self.assertTrue(self.check())
        self.assertTrue(self.check(environment="test", url="https://api.qiafan.cn/api/v1"))

    def test_debug_keeps_development_working(self):
        self.assertEqual([], self.check("Debug", "test", ""))

    def test_testflight_has_an_exact_test_backend_and_does_not_relax_release(self):
        approved = "https://test-api.yzsalingo.com/api/v1"
        self.assertEqual([], self.check("TestFlight", "test", approved))
        self.assertTrue(self.check("Release", "test", approved))
        self.assertTrue(self.check("TestFlight", "production", approved))
        for url in ["", "https://api.qiafan.cn/api/v1", approved + "?x=1",
                    approved.replace("https:", "http:")]:
            self.assertTrue(self.check("TestFlight", "test", url))

    def test_testflight_rejects_debug_diagnostics(self):
        import os
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                                env={**os.environ, "CONFIGURATION": "TestFlight",
                                     "QF_API_ENVIRONMENT": "test",
                                     "QF_API_BASE_URL": "https://test-api.yzsalingo.com/api/v1",
                                     "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"})
        self.assertEqual(1, result.returncode)
        self.assertIn("DEBUG", result.stderr)

    def test_release_accepts_https_production_api_format(self):
        for url in ["https://api.qiafan.cn/api/v1", "https://api.qiafan.cn:443/api/v1/"]:
            with self.subTest(url=url):
                self.assertEqual([], self.check(url=url))

    def test_release_rejects_nonproduction_or_ambiguous_addresses(self):
        for url in [
            "http://api.qiafan.cn/api/v1", "$(QF_API_BASE_URL)",
            "https://test-api.yzsalingo.com/api/v1", "https://staging.qiafan.cn/api/v1",
            "https://dev.qiafan.cn/api/v1", "https://localhost/api/v1",
            "https://127.0.0.1/api/v1", "https://[::1]/api/v1",
            "https://127.1/api/v1", "https://127.0.1/api/v1",
            "https://0177.1/api/v1", "https://127.0x1/api/v1",
            "https://0x7f000001/api/v1",
            "https://192.168.1.2/api/v1", "https://api.example.com/api/v1",
            "https://api.qiafan.invalid/api/v1", "https://api.local/api/v1",
            "https://user:secret@api.qiafan.cn/api/v1", "https://api.qiafan.cn/api/v1?q=x",
            "https://api.qiafan.cn/api/v1#x", "https://api.qiafan.cn:8443/api/v1",
            "https://api.qiafan.cn/api/v2", " https://api.qiafan.cn/api/v1",
            "https://api.qiafan.cn/\napi/v1", "https://api.qiafan.cn\\evil/api/v1",
            "https://api..qiafan.cn/api/v1", "https://-api.qiafan.cn/api/v1",
        ]:
            with self.subTest(url=url):
                self.assertTrue(self.check(url=url))

    def test_cli_fails_without_printing_credentials(self):
        import os
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                                env={**os.environ, "CONFIGURATION": "Release",
                                     "QF_API_ENVIRONMENT": "production",
                                     "QF_API_BASE_URL": "https://user:do-not-log@api.qiafan.cn/api/v1"})
        self.assertEqual(1, result.returncode)
        self.assertIn("error:", result.stderr)
        self.assertNotIn("do-not-log", result.stderr + result.stdout)

    def test_development_extension_project_cannot_be_archived_as_release(self):
        import os
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                                env={**os.environ, "CONFIGURATION": "Release",
                                     "QF_API_ENVIRONMENT": "production",
                                     "QF_API_BASE_URL": "https://api.qiafan.cn/api/v1",
                                     "QF_DEVELOPMENT_EXTENSIONS": "YES"})
        self.assertEqual(1, result.returncode)
        self.assertIn("development", result.stderr)

    def test_release_metadata_keeps_retained_values_and_rejects_drift(self):
        spec = importlib.util.spec_from_file_location("release_configuration", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "QiafanYoupu").mkdir()
            (root / "Configuration").mkdir()
            source = {"CFBundleDisplayName": "Test", "CFBundleURLTypes": [{"CFBundleURLSchemes": ["test"]}],
                      "NSCameraUsageDescription": "Debug camera"}
            release = {key: value for key, value in source.items() if not key.startswith("NSCamera")}
            (root / "QiafanYoupu/Info.plist").write_bytes(plistlib.dumps(source))
            target = root / "Configuration/Info-CoreRelease.plist"
            target.write_bytes(plistlib.dumps(release))
            self.assertEqual([], module.validate_metadata(root))
            target.write_bytes(plistlib.dumps(source))
            self.assertTrue(module.validate_metadata(root))
            release["CFBundleURLTypes"] = []
            target.write_bytes(plistlib.dumps(release))
            self.assertTrue(module.validate_metadata(root))
            target.unlink()
            self.assertTrue(module.validate_metadata(root))


if __name__ == "__main__":
    unittest.main()
