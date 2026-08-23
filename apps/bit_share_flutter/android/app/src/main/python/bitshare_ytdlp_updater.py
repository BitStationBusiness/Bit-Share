"""Keeps the embedded yt-dlp current without shipping a whole new APK.

YouTube changes what its player accepts every few weeks, and the version of
yt-dlp baked into the APK by Chaquopy can only move when a new APK is built,
signed and installed. That is far slower than the breakage, so downloads stop
working for weeks at a time between releases.

`docs/UPDATE_PROTOCOL.md` allows this only with four guarantees, and each one
is implemented here:

* **verified** — the wheel is checked against the SHA-256 PyPI publishes for
  that exact file before anything is unpacked, and the archive is rejected if
  it tries to write outside its own directory;
* **versioned** — every download lands in its own directory named after its
  version, and `active.json` records which one is in use;
* **isolated** — updates live in app-private storage and are only ever put in
  front of the bundled copy on `sys.path`; nothing in the APK is modified, so
  the shipped version is always still there;
* **rollback** — activation imports the override before trusting it, and any
  failure clears the record so the next start falls back to the bundled copy.

Only yt-dlp is handled. curl-cffi and CPython stay pinned to the APK: they
carry compiled code, which is a different problem entirely.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import zipfile

PACKAGE = "yt-dlp"
_INDEX_URL = "https://pypi.org/pypi/yt-dlp/json"
_MANIFEST = "active.json"
_MAX_WHEEL_BYTES = 32 * 1024 * 1024
_TIMEOUT = 30

# Set by activate() so the rest of the module knows where it may write.
_root = None


def _requests():
    # Imported lazily: activate() runs before yt-dlp itself is imported, and
    # pulling curl_cffi in at module scope would drag its native library into
    # every start even when no update check happens.
    from curl_cffi import requests

    return requests


def _version_tuple(value):
    return tuple(int(part) for part in re.findall(r"\d+", value or ""))


def _manifest_path():
    return os.path.join(_root, _MANIFEST)


def _read_manifest():
    try:
        with open(_manifest_path(), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    version = data.get("version")
    path = data.get("path")
    if not version or not path or not os.path.isdir(path):
        return None
    return {"version": str(version), "path": str(path)}


def _write_manifest(version, path):
    temporary = _manifest_path() + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump({"version": version, "path": path}, handle)
    os.replace(temporary, _manifest_path())


def _clear_manifest():
    try:
        os.remove(_manifest_path())
    except OSError:
        pass


def _imported_version():
    """Version of the yt-dlp actually bound in this process."""
    import yt_dlp.version

    return yt_dlp.version.__version__


def _current_version():
    """What an update has to beat: the override if one is active, else the
    version that got imported (the APK's copy on a clean start)."""
    record = _read_manifest()
    return record["version"] if record else _imported_version()


def activate(root):
    """Puts a previously downloaded yt-dlp in front of the bundled one.

    Called before `bitshare_ytdlp` is imported, because `sys.path` has to be
    in its final shape before `import yt_dlp` binds a version.
    """
    global _root
    _root = root
    os.makedirs(_root, exist_ok=True)

    record = _read_manifest()
    if record is None:
        return json.dumps({"active": None, "source": "bundled"})

    path = record["path"]
    if path in sys.path:
        return json.dumps({"active": record["version"], "source": "update"})

    sys.path.insert(0, path)
    try:
        # Trusting the record is not enough: a half-extracted or
        # incompatible copy has to be caught here, while falling back is
        # still just a matter of removing an entry from sys.path.
        import yt_dlp
        import yt_dlp.version

        active = yt_dlp.version.__version__
        loaded_from = os.path.realpath(os.path.dirname(yt_dlp.__file__))
        expected = os.path.realpath(path)
        if not loaded_from.startswith(expected + os.sep):
            # Something else on sys.path won. Better the APK's known-good
            # copy than a version we cannot account for.
            raise ImportError("yt-dlp did not load from the update directory")
    except Exception:  # noqa: BLE001 - any failure means "use the APK copy"
        sys.path.remove(path)
        for name in [n for n in sys.modules if n.split(".")[0] == "yt_dlp"]:
            del sys.modules[name]
        _clear_manifest()
        shutil.rmtree(path, ignore_errors=True)
        return json.dumps({"active": None, "source": "bundled-rollback"})

    return json.dumps({"active": active, "source": "update"})


def _latest_release():
    response = _requests().get(_INDEX_URL, timeout=_TIMEOUT)
    response.raise_for_status()
    payload = response.json()
    version = str(payload["info"]["version"])
    for item in payload.get("urls") or []:
        if item.get("packagetype") != "bdist_wheel":
            continue
        if not str(item.get("filename", "")).endswith("py3-none-any.whl"):
            continue
        digest = (item.get("digests") or {}).get("sha256")
        if not digest:
            continue
        return {
            "version": version,
            "url": str(item["url"]),
            "sha256": str(digest),
            "size": int(item.get("size") or 0),
        }
    return None


def _safe_extract(archive, destination):
    """Unpacks a wheel, refusing any member that escapes [destination]."""
    root = os.path.realpath(destination)
    for member in archive.namelist():
        target = os.path.realpath(os.path.join(destination, member))
        if target != root and not target.startswith(root + os.sep):
            raise ValueError("BITSHARE_WHEEL_PATH_ESCAPE")
    archive.extractall(destination)


def check_and_install(force=False):
    """Downloads a newer yt-dlp when there is one.

    Returns a JSON summary; never raises, because a failed check must not
    stop the user from downloading with the version already installed.
    """
    if _root is None:
        return json.dumps({"status": "not-configured"})

    try:
        current_version = _current_version()
        latest = _latest_release()
        if latest is None:
            return json.dumps({"status": "no-wheel"})
        if not force and _version_tuple(latest["version"]) <= _version_tuple(
            current_version
        ):
            return json.dumps(
                {"status": "current", "version": current_version}
            )
        if latest["size"] and latest["size"] > _MAX_WHEEL_BYTES:
            return json.dumps({"status": "too-large"})

        response = _requests().get(latest["url"], timeout=_TIMEOUT)
        response.raise_for_status()
        payload = response.content
        if len(payload) > _MAX_WHEEL_BYTES:
            return json.dumps({"status": "too-large"})

        digest = hashlib.sha256(payload).hexdigest()
        if digest != latest["sha256"].lower():
            # The only integrity guarantee available here, so a mismatch is
            # fatal rather than a warning.
            return json.dumps({"status": "checksum-mismatch"})

        staging = os.path.join(_root, ".staging")
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging, exist_ok=True)
        wheel_path = os.path.join(staging, "yt_dlp.whl")
        with open(wheel_path, "wb") as handle:
            handle.write(payload)
        unpacked = os.path.join(staging, "unpacked")
        os.makedirs(unpacked, exist_ok=True)
        with zipfile.ZipFile(wheel_path) as archive:
            _safe_extract(archive, unpacked)
        if not os.path.isdir(os.path.join(unpacked, "yt_dlp")):
            shutil.rmtree(staging, ignore_errors=True)
            return json.dumps({"status": "unexpected-wheel"})

        final = os.path.join(_root, latest["version"])
        shutil.rmtree(final, ignore_errors=True)
        os.replace(unpacked, final)
        shutil.rmtree(staging, ignore_errors=True)
        _write_manifest(latest["version"], final)
        _prune(keep=latest["version"])
        # Deliberately not activated in this process: yt-dlp is already
        # imported by now, and swapping it underneath a running download is
        # how you get a half-old, half-new module. It takes effect next start.
        return json.dumps(
            {
                "status": "installed",
                "version": latest["version"],
                "previous": current_version,
            }
        )
    except Exception as error:  # noqa: BLE001 - reported, never propagated
        return json.dumps({"status": "failed", "detail": type(error).__name__})


def _prune(keep):
    """Leaves only the version in use, so downloads cannot pile up."""
    for name in os.listdir(_root):
        path = os.path.join(_root, name)
        if not os.path.isdir(path) or name == keep:
            continue
        shutil.rmtree(path, ignore_errors=True)


def status():
    record = _read_manifest()
    return json.dumps(
        {
            "imported": _imported_version(),
            "active": _current_version(),
            "source": "update" if record else "bundled",
        }
    )
