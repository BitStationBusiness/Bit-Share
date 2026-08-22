"""Small, privacy-preserving yt-dlp bridge for the Android host app."""

import base64
import json
import os
import re
import subprocess
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlparse

import yt_dlp
from curl_cffi import requests
from yt_dlp.networking.impersonate import ImpersonateTarget
from yt_dlp.utils import DownloadCancelled, DownloadError


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


def _base_options(cookies_path=None):
    options = {
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        # Progress reaches the UI through the Kotlin callback; yt-dlp's own
        # bar would only ever be written to logcat.
        "noprogress": True,
        "impersonate": ImpersonateTarget.from_str("chrome"),
    }
    # Only set when the user explicitly logged in through Bit-Share's own
    # in-app browser (see LoginSessionActivity) — never copied from another
    # app's session store.
    if cookies_path and os.path.isfile(cookies_path):
        options["cookiefile"] = cookies_path
    return options


# Android ships no JavaScript runtime: neither Deno nor Node exists inside the
# APK, and yt-dlp's EJS challenge solver is not bundled either. Every YouTube
# player client that has to solve the `n` challenge therefore answers with
# storyboard tiles and nothing else, so extraction can only lean on the
# clients that still hand back real media without JS. yt-dlp's own default
# chain runs first — it tracks upstream and normally picks a working client —
# and these are the manual fallbacks for when a YouTube-side change breaks
# that default before a new yt-dlp release reaches the app.
_YOUTUBE_CLIENT_FALLBACKS = (
    ("visionos", "tv_embedded"),
    ("android", "ios", "mweb"),
    ("web_safari", "web", "tv"),
)

_YOUTUBE_HOSTS = ("youtube.com", "youtu.be", "youtube-nocookie.com")


class _NoPlayableFormats(Exception):
    """Raised when an extraction succeeded but produced no real media."""


def _is_youtube_url(url):
    hostname = urlparse(url).hostname
    return any(_host_matches(hostname, host) for host in _YOUTUBE_HOSTS)


def _client_variants(url):
    """Option overrides to try in order, most preferred first.

    Non-YouTube URLs keep exactly one attempt, so no other provider changes
    behaviour because of this.
    """
    if not _is_youtube_url(url):
        return ({},)
    return ({},) + tuple(
        {"extractor_args": {"youtube": {"player_client": list(clients)}}}
        for clients in _YOUTUBE_CLIENT_FALLBACKS
    )


def _error_chain(error):
    seen = set()
    current = error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        yield current
        current = current.__cause__ or current.__context__


def _is_cancellation(error):
    return isinstance(error, DownloadCancelled) or any(
        "BITSHARE_CANCELLED" in str(item) for item in _error_chain(error)
    )


def _has_playable_format(info):
    """True when the extraction returned something other than storyboards.

    A client that cannot solve the `n` challenge still returns a perfectly
    valid info dict — it just holds nothing but `mhtml` preview tiles.
    Accepting that would show "this link has no video" to the user while a
    different client would have worked, so it counts as a failure and lets
    the next candidate run.
    """
    for item in info.get("formats") or ():
        if item.get("ext") == "mhtml":
            continue
        video = item.get("vcodec")
        audio = item.get("acodec")
        if (video and video != "none") or (audio and audio != "none"):
            return True
    return False


def _attempt_with_clients(url, build_options, run):
    """Run `run` against each candidate client set until one succeeds."""
    failure = None
    for overrides in _client_variants(url):
        options = build_options()
        options.update(overrides)
        try:
            return run(options)
        except (
            DownloadError,
            _NoPlayableFormats,
            ValueError,
            OSError,
        ) as error:
            if _is_cancellation(error):
                raise
            failure = error
    raise failure


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


def _is_meta_story_url(url):
    # Facebook's and Instagram's `/stories/...` path is shared by two
    # different things: real 24h ephemeral Stories (which yt-dlp cannot
    # extract at all) AND, on Facebook, its full-screen swipeable viewer for
    # Reels/videos (which yt-dlp usually *can* extract once resolved). The
    # path alone cannot tell them apart, so it is only used to improve the
    # error message after yt-dlp itself has already failed on the URL — see
    # _reraise_meta_story — never to block the attempt up front.
    parsed = urlparse(url)
    return (
        _host_matches(parsed.hostname, "facebook.com")
        or _host_matches(parsed.hostname, "instagram.com")
    ) and parsed.path.startswith("/stories/")


def _reraise_meta_story(url, error):
    if _is_meta_story_url(url) and "Unsupported URL" in str(error):
        return ValueError("BITSHARE_META_STORY_NOT_SUPPORTED")
    return error


def _is_meta_cdn_media_url(url):
    # LoginSessionActivity's Story-mode network capture (see
    # shouldInterceptRequest in LoginSessionActivity.kt) hands back the raw
    # file the story player itself fetched, on fbcdn.net (Facebook) or
    # cdninstagram.com (Instagram) rather than the page's own host. That is
    # just a direct progressive video URL — no extractor needed, the same
    # way _resolve_public_threads_video's media_url is used directly below.
    hostname = urlparse(url).hostname
    return _host_matches(hostname, "fbcdn.net") or _host_matches(
        hostname, "cdninstagram.com"
    )


def _meta_referer(url):
    # Instagram content is frequently served from the same fbcdn.net hosts
    # as Facebook (cdninstagram.com is not a reliable signal either way), so
    # the CDN host cannot be used to tell which page the request came from.
    # A facebook.com Referer has worked for both in practice — Meta's CDN
    # does not appear to validate it strictly per-property.
    return "https://www.facebook.com/"


def _meta_story_height(url):
    # Meta's CDN encodes the actual encode height in the `efg` query
    # parameter (same field _threads_progressive_height reads for Threads);
    # unlike that call site there is no known original width/height here to
    # scale a partial match against, so only the explicit "720p"-style tag
    # is usable. A default placeholder covers the common case where `efg`
    # is absent (the URL was matched by its `.mp4` extension instead) —
    # DownloadCoordinator only shows this as a label, the actual file is
    # whatever resolution the story player itself fetched regardless.
    try:
        encoded = parse_qs(urlparse(url).query)["efg"][0]
        padding = "=" * (-len(encoded) % 4)
        metadata = json.loads(base64.b64decode(encoded + padding))
        tag = str(metadata.get("vencode_tag") or "")
        explicit = re.search(r"(?:^|[_-])(\d{3,4})p(?:$|[_.-])", tag)
        if explicit:
            return int(explicit.group(1))
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        pass
    return 720


def _meta_cdn_content_length(url):
    try:
        probe = requests.head(
            url,
            impersonate="chrome",
            headers={"Referer": _meta_referer(url)},
            timeout=30,
        )
        if probe.ok:
            return _positive_number(
                int(probe.headers.get("content-length") or 0)
            )
    except (TypeError, ValueError):
        pass
    return None


def _probe_meta_story_media(url, audio_url=None):
    video_size = _meta_cdn_content_length(url) or 0
    audio_size = _meta_cdn_content_length(audio_url) if audio_url else 0
    total_size = _positive_number(video_size + (audio_size or 0))
    return json.dumps(
        {
            "id": "meta-story",
            "title": "Historia",
            "formats": [
                {
                    "formatId": "meta-story-progressive",
                    "extension": "mp4",
                    "audioCodec": "aac" if audio_url else "none",
                    "videoCodec": "h264",
                    "height": _meta_story_height(url),
                    "fileSize": total_size,
                    "fileSizeApproximate": None,
                    "audioBitrate": None,
                    "totalBitrate": None,
                }
            ],
        },
        ensure_ascii=False,
    )


def _download_meta_cdn_file(
    url, dest_path, callback, progress_offset, progress_span
):
    # Deliberately not `with requests.get(...) as response:` — curl_cffi's
    # response object is not guaranteed to support the context-manager
    # protocol the way `requests` does; closing explicitly in `finally`
    # works regardless of that.
    response = requests.get(
        url,
        impersonate="chrome",
        headers={"Referer": _meta_referer(url)},
        timeout=60,
        stream=True,
    )
    try:
        response.raise_for_status()
        total = int(response.headers.get("content-length") or 0)
        downloaded = 0
        with open(dest_path, "wb") as handle:
            for chunk in response.iter_content(chunk_size=262144):
                if callback.isCancelled():
                    raise DownloadCancelled("BITSHARE_CANCELLED")
                if not chunk:
                    continue
                handle.write(chunk)
                downloaded += len(chunk)
                if total > 0:
                    fraction = min(1.0, downloaded / total)
                    callback.onProgressUpdate(
                        progress_offset + fraction * progress_span, 0
                    )
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()


def _run_ffmpeg(ffmpeg_location, args):
    binary = os.path.join(ffmpeg_location, "ffmpeg")
    result = subprocess.run(
        [binary, "-y", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "BITSHARE_FFMPEG_MUX_FAILED: "
            + result.stdout.decode("utf-8", errors="replace")[-2000:]
        )


def _download_meta_story(
    url,
    audio_url,
    output_template,
    mode,
    ffmpeg_location,
    callback,
):
    directory = os.path.dirname(output_template)
    os.makedirs(directory, exist_ok=True)
    video_tmp = os.path.join(directory, "_meta_story_video.tmp")
    audio_tmp = os.path.join(directory, "_meta_story_audio.tmp")
    try:
        video_span = 50.0 if audio_url else 100.0
        _download_meta_cdn_file(url, video_tmp, callback, 0.0, video_span)
        if audio_url:
            _download_meta_cdn_file(
                audio_url, audio_tmp, callback, video_span, 100.0 - video_span
            )

        if mode == "audio":
            final_path = os.path.join(directory, "Historia.m4a")
            source = audio_tmp if audio_url else video_tmp
            _run_ffmpeg(
                ffmpeg_location,
                ["-i", source, "-vn", "-c:a", "aac", final_path],
            )
        else:
            final_path = os.path.join(directory, "Historia.mp4")
            if audio_url:
                _run_ffmpeg(
                    ffmpeg_location,
                    [
                        "-i", video_tmp,
                        "-i", audio_tmp,
                        "-c", "copy",
                        "-movflags", "+faststart",
                        final_path,
                    ],
                )
            else:
                _run_ffmpeg(
                    ffmpeg_location,
                    ["-i", video_tmp, "-c", "copy", final_path],
                )
        callback.onProgressUpdate(100.0, 0)
        return 0
    finally:
        for tmp in (video_tmp, audio_tmp):
            try:
                if os.path.isfile(tmp):
                    os.remove(tmp)
            except OSError:
                pass


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


def inspect_media(url, cookies_path=None, audio_url=None):
    if _is_instagram_story_share(url):
        raise ValueError("BITSHARE_INSTAGRAM_STORY_REQUIRES_SESSION")
    if _is_meta_cdn_media_url(url):
        return _probe_meta_story_media(url, audio_url)

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

    def build_options():
        options = _base_options(cookies_path)
        options["skip_download"] = True
        return options

    def run(options):
        with yt_dlp.YoutubeDL(options) as downloader:
            try:
                extracted = downloader.extract_info(url, download=False)
            except DownloadError as error:
                raise _reraise_meta_story(url, error) from error
        # Only YouTube is gated on this: other extractors legitimately omit
        # codec metadata, and rejecting those would break providers that
        # work today.
        if _is_youtube_url(url) and not _has_playable_format(extracted):
            raise _NoPlayableFormats("BITSHARE_NO_PLAYABLE_FORMATS")
        return extracted

    info = _attempt_with_clients(url, build_options, run)

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
    cookies_path=None,
    audio_url=None,
):
    os.environ["LD_LIBRARY_PATH"] = ffmpeg_library_path
    if _is_instagram_story_share(url):
        raise ValueError("BITSHARE_INSTAGRAM_STORY_REQUIRES_SESSION")

    if _is_meta_cdn_media_url(url):
        # No extractor involved at all: both tracks are already-resolved
        # direct CDN files (see LoginSessionActivity's capture), so this
        # downloads and muxes them directly instead of going through
        # yt-dlp's extract/download pipeline, which has nothing to extract
        # here in the first place.
        return _download_meta_story(
            url, audio_url, output_template, mode, ffmpeg_location, callback
        )

    threads_media = _resolve_public_threads_video(url, include_size=False)

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

    def build_options():
        options = _base_options(cookies_path)
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
        options["progress_hooks"] = [progress_hook]
        return options

    target_url = threads_media["media_url"] if threads_media else url

    def run(options):
        with yt_dlp.YoutubeDL(options) as downloader:
            try:
                exit_code = int(downloader.download([target_url]) or 0)
            except DownloadError as error:
                raise _reraise_meta_story(target_url, error) from error
        # A non-zero exit means yt-dlp gave up without raising. Turning it
        # into an exception is what lets the next player client be tried
        # instead of reporting the failure straight to the user.
        if exit_code != 0:
            raise DownloadError(
                "BITSHARE_ENGINE_EXIT_" + str(exit_code)
            )
        return exit_code

    # The fallback chain is keyed on the page URL, not on the already
    # resolved Threads CDN file: only YouTube pages have alternate clients.
    return _attempt_with_clients(url, build_options, run)


def runtime_info():
    import curl_cffi

    return json.dumps(
        {
            "ytDlp": yt_dlp.version.__version__,
            "curlCffi": curl_cffi.__version__,
        }
    )
