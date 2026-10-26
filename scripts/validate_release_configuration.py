"""Build-time validation; never logs configuration values or makes requests."""
import os
import ipaddress
import re
import sys
import plistlib
from pathlib import Path
from urllib.parse import urlsplit


def validate(configuration, environment, raw_url):
    if configuration == "Debug":
        return []
    errors = []
    if environment != "production":
        errors.append("Release requires QF_API_ENVIRONMENT=production.")
    message = "Release requires a formal HTTPS QF_API_BASE_URL ending in /api/v1; configure Configuration/Release.local.xcconfig or the build setting."
    if not raw_url or any(c.isspace() or ord(c) < 32 for c in raw_url) or "\\" in raw_url:
        return errors + [message]
    try:
        url = urlsplit(raw_url)
        host = url.hostname or ""
        labels = host.split(".")
        valid = (url.scheme == "https" and len(labels) > 1
                 and re.fullmatch(r"[a-z][a-z0-9-]*", labels[-1]) is not None
                 and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in labels)
                 and url.port in (None, 443) and url.username is None and url.password is None
                 and url.path in ("/api/v1", "/api/v1/") and not url.query and not url.fragment)
        # Production uses a DNS name, never a local or public numeric address.
        try:
            ipaddress.ip_address(host)
            valid = False
        except ValueError:
            pass
        tokens = set(re.split(r"[.-]", host))
        if tokens & {"test", "testing", "dev", "development", "staging", "stage", "sandbox", "localhost"}:
            valid = False
        if labels[-1] in {"local", "localhost", "invalid", "test", "example", "internal"} or host in {"example.com", "example.net", "example.org"} or host.endswith((".example.com", ".example.net", ".example.org")):
            valid = False
        if not valid:
            errors.append(message)
    except ValueError:
        errors.append(message)
    return errors


def validate_metadata(project_root):
    """Keep the standard Release plist aligned while excluding deferred purposes."""
    purposes = {"NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                "NSSpeechRecognitionUsageDescription", "NSPhotoLibraryUsageDescription"}
    try:
        with (project_root / "QiafanYoupu/Info.plist").open("rb") as source:
            development = plistlib.load(source)
        with (project_root / "Configuration/Info-CoreRelease.plist").open("rb") as source:
            release = plistlib.load(source)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return ["Release metadata is missing or invalid; check both source Info.plist files."]
    expected = {key: value for key, value in development.items() if key not in purposes}
    if any(key in release for key in purposes) or release != expected:
        return ["Release metadata must match the development Info.plist without deferred camera, microphone, speech or photo-library purposes."]
    return []


def main():
    errors = validate(os.environ.get("CONFIGURATION", "Release"),
                      os.environ.get("QF_API_ENVIRONMENT", ""),
                      os.environ.get("QF_API_BASE_URL", ""))
    if os.environ.get("CONFIGURATION", "Release") != "Debug" and os.environ.get("QF_DEVELOPMENT_EXTENSIONS") == "YES":
        errors.append("Release cannot use the development extension project; regenerate with project.yml.")
    if os.environ.get("CONFIGURATION", "Release") != "Debug":
        errors.extend(validate_metadata(Path(__file__).resolve().parents[1]))
    for error in errors:
        print("error: " + error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
