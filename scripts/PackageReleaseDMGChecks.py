#!/usr/bin/env python3
"""Exercise the release DMG installer path with a real signed fixture app."""

from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGER = ROOT / "scripts" / "package-release-dmg.sh"


def run(*args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=True, text=True, **kwargs)


def make_signed_app(parent: Path) -> Path:
    app = parent / "Fixture.app"
    executable = app / "Contents" / "MacOS" / "Fixture"
    executable.parent.mkdir(parents=True)
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o755)
    plist = {
        "CFBundleExecutable": "Fixture",
        "CFBundleIdentifier": "com.example.InterestingNotchPackagingFixture",
        "CFBundleName": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
    }
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(plist))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", str(app))
    return app


def mounted_volume(dmg: Path) -> str:
    attached = run("hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(dmg), capture_output=True)
    entities = plistlib.loads(attached.stdout.encode())["system-entities"]
    return next(entity["mount-point"] for entity in entities if "mount-point" in entity)


def test_installer_volume_exposes_applications_link() -> None:
    with tempfile.TemporaryDirectory(prefix="interesting-notch-dmg-check-") as temporary:
        workspace = Path(temporary)
        app = make_signed_app(workspace)
        dmg = workspace / "fixture.dmg"
        run(str(PACKAGER), str(app), str(dmg), "Fixture Installer")
        run("hdiutil", "verify", str(dmg), capture_output=True)

        mount_point = mounted_volume(dmg)
        try:
            visible_items = {item.name for item in Path(mount_point).iterdir() if not item.name.startswith(".")}
            assert visible_items == {"Fixture.app", "Applications"}, visible_items
            applications = Path(mount_point) / "Applications"
            assert applications.is_symlink()
            assert os.readlink(applications) == "/Applications"
        finally:
            run("hdiutil", "detach", mount_point, "-quiet")


if __name__ == "__main__":
    test_installer_volume_exposes_applications_link()
    print("Release DMG installer checks passed.")
