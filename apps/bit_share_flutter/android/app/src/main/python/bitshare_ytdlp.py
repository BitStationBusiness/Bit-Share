"""Small, privacy-preserving yt-dlp bridge for the Android host app."""

import base64
import json
import os
import re
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlparse

import yt_dlp
from curl_cffi import requests
from yt_dlp.networking.impersonate import ImpersonateTarget
from yt_dlp.utils import DownloadCancelled


class _JsonScriptCollector(HTMLParser):
    def __init__(self):
        super().__init__()
        self._in_script = False
        self._attributes = {}
        self._chunks = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self._in_script = True
            self._attributes = dict(attrs)
            self._chunks = []

    def handle_data(self, data):
        if self._in_script:
            self._chunks.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self._in_script:
            self.scripts.append(
                (self._attributes, "".join(self._chunks))
            )
            self._in_script = False


def _base_options():
    return {
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "impersonate": ImpersonateTarget.from_str("chrome"),
    }


def _positive_number(value):
    if isinstance(value, (int, float)) and value > 0:
        return value
    return None


def _host_matches(host, expected):
    normalized = (host or "").lower().rstrip(".")
    return normalized == expected or normalized.endswith("." + expected)


def _is_instagram_story_share(url):
    parsed = urlparse(url)
    return (
        _host_matches(parsed.hostname, "instagram.com")
        and parsed.path.startswith("/s/")
    )


def _find_threads_media(value, shortcode):
    if isinstance(value, dict):
        if value.get("code") == shortcode:
            if value.get("video_versions"):
                return value
            for item in value.get("carousel_media") or []:
                if isinstance(item, dict) and item.get("video_versions"):
                    return item
        for child in value.values():
            match = _find_threads_media(child, shortcode)
            if match:
                return match
    elif isinstance(value, list):
        for child in value:
            match = _find_threads_media(child, shortcode)
            if match:
                return match
    return None


def _threads_progressive_height(media_url, width, height):
    try:
        encoded = parse_qs(urlparse(media_url).query)["efg"][0]
        padding = "=" * (-len(encoded) % 4)
        metadata = json.loads(base64.b64decode(encoded + padding))
        tag = str(metadata.get("vencode_tag") or "")
        explicit = re.search(r"(?:^|[_-])(\d{3,4})p(?:$|[_.-])", tag)
        if explicit:
            return int(explicit.group(1))
        max_dimension = re.search(r"\.C\d+\.(\d{3,4})\.", tag)
        if max_dimension and width and height:
            scale = int(max_dimension.group(1)) / max(width, height)
            scaled_height = int(round((height * scale) / 2) * 2)
            return scaled_height if scaled_height > 0 else None
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
    return None


def _resolve_public_threads_video(url, include_size):
    parsed = urlparse(url)
    if not _host_matches(parsed.hostname, "threads.com"):
        return None

    response = requests.get(
        url,
        impersonate="chrome",
        allow_redirects=True,
        timeout=30,
    )
    response.raise_for_status()
    final_url = str(response.url)
    final_parsed = urlparse(final_url)
    if not _host_matches(final_parsed.hostname, "threads.com"):
        raise ValueError("BITSHARE_THREADS_INVALID_REDIRECT")

    path_parts = [
        part for part in final_parsed.path.split("/") if part
    ]
    try:
        post_index = path_parts.index("post")
        shortcode = path_parts[post_index + 1]
    except (ValueError, IndexError):
        raise ValueError("BITSHARE_THREADS_POST_NOT_FOUND")

    collector = _JsonScriptCollector()
    collector.feed(response.text)
    media = None
    for attributes, body in collector.scripts:
        if (
            attributes.get("type") != "application/json"
            or shortcode not in body
        ):
            continue
        try:
            media = _find_threads_media(json.loads(body), shortcode)
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if media:
            break
    if not media:
        raise ValueError("BITSHARE_THREADS_PUBLIC_VIDEO_NOT_FOUND")

    versions = media.get("video_versions") or []
    media_url = next(
        (
            str(item.get("url"))
            for item in versions
            if isinstance(item, dict) and item.get("url")
        ),
        None,
    )
    media_parsed = urlparse(media_url or "")
    if (
        media_parsed.scheme != "https"
        or not (
            _host_matches(media_parsed.hostname, "fbcdn.net")
            or _host_matches(media_parsed.hostname, "cdninstagram.com")
        )
    ):
        raise ValueError("BITSHARE_THREADS_UNSAFE_MEDIA_URL")

    file_size = None
    if include_size:
        try:
            probe = requests.head(
                media_url,
                impersonate="chrome",
                headers={"Referer": final_url},
                timeout=30,
            )
            if probe.ok:
                file_size = _positive_number(
                    int(probe.headers.get("content-length") or 0)
                )
        except (TypeError, ValueError):
            file_size = None

    original_height = _positive_number(media.get("original_height"))
    original_width = _positive_number(media.get("original_width"))
    return {
        "id": str(media.get("id") or shortcode),
        "title": "Threads " + shortcode,
        "page_url": final_url,
        "media_url": media_url,
        "height": (
            _threads_progressive_height(
                media_url,
                original_width,
                original_height,
            )
            or original_height
        ),
        "width": original_width,
        "file_size": file_size,
        "has_audio": bool(media.get("has_audio")),
    }


def inspect_media(url):
    if _is_instagram_story_share(url):
        raise ValueError("BITSHARE_INSTAGRAM_STORY_REQUIRES_SESSION")

    threads_media = _resolve_public_threads_video(url, include_size=True)
    if threads_media:
        return json.dumps(
            {
                "id": threads_media["id"],
                "title": threads_media["title"],
                "formats": [
                    {
                        "formatId": "threads-progressive",
                        "extension": "mp4",
                        "audioCodec": (
                            "aac" if threads_media["has_audio"] else "none"
                        ),
                        "videoCodec": "h264",
                        "height": threads_media["height"],
                        "fileSize": threads_media["file_size"],
                        "fileSizeApproximate": None,
                        "audioBitrate": None,
                        "totalBitrate": None,
                    }
                ],
            },
            ensure_ascii=False,
        )

    options = _base_options()
    options["skip_download"] = True

    with yt_dlp.YoutubeDL(options) as downloader:
        info = downloader.extract_info(url, download=False)

    formats = []
    for item in info.get("formats") or []:
        formats.append(
            {
                "formatId": item.get("format_id"),
                "extension": item.get("ext"),
                "audioCodec": item.get("acodec"),
                "videoCodec": item.get("vcodec"),
                "height": _positive_number(item.get("height")),
                "fileSize": _positive_number(item.get("filesize")),
                "fileSizeApproximate": _positive_number(
                    item.get("filesize_approx")
                ),
                "audioBitrate": _positive_number(item.get("abr")),
                "totalBitrate": _positive_number(item.get("tbr")),
            }
        )

    return json.dumps(
        {
            "id": info.get("id"),
            "title": info.get("title"),
            "formats": formats,
        },
        ensure_ascii=False,
    )


def download_media(
    url,
    output_template,
    format_selector,
    mode,
    ffmpeg_location,
    ffmpeg_library_path,
    callback,
):
    os.environ["LD_LIBRARY_PATH"] = ffmpeg_library_path
    if _is_instagram_story_share(url):
        raise ValueError("BITSHARE_INSTAGRAM_STORY_REQUIRES_SESSION")

    threads_media = _resolve_public_threads_video(url, include_size=False)
    options = _base_options()
    options.update(
        {
            "format": "best" if threads_media else format_selector,
            "outtmpl": output_template,
            "restrictfilenames": True,
            "retries": 3,
            "fragment_retries": 3,
            "socket_timeout": 30,
            "ffmpeg_location": ffmpeg_location,
        }
    )
    if threads_media:
        options["http_headers"] = {
            "Referer": threads_media["page_url"],
        }
        options["outtmpl"] = os.path.join(
            os.path.dirname(output_template),
            "Threads [" + threads_media["id"] + "].%(ext)s",
        )

    if mode == "audio":
        options["postprocessors"] = [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "m4a",
            }
        ]
    else:
        options["merge_output_format"] = "mp4"

    def progress_hook(status):
        if callback.isCancelled():
            raise DownloadCancelled("BITSHARE_CANCELLED")
        if status.get("status") != "downloading":
            return
        raw_percent = str(status.get("_percent_str") or "0").strip()
        try:
            percent = float(raw_percent.replace("%", "").strip())
        except ValueError:
            downloaded = status.get("downloaded_bytes") or 0
            total = (
                status.get("total_bytes")
                or status.get("total_bytes_estimate")
                or 0
            )
            percent = (downloaded * 100.0 / total) if total else 0.0
        callback.onProgressUpdate(
            percent,
            int(status.get("eta") or 0),
        )

    options["progress_hooks"] = [progress_hook]

    with yt_dlp.YoutubeDL(options) as downloader:
        target_url = (
            threads_media["media_url"] if threads_media else url
        )
        return int(downloader.download([target_url]) or 0)


def runtime_info():
    import curl_cffi

    return json.dumps(
        {
            "ytDlp": yt_dlp.version.__version__,
            "curlCffi": curl_cffi.__version__,
        }
    )
