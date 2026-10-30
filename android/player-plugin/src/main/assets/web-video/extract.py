"""Pinned yt-dlp API runner. Credentials arrive on stdin and never touch disk/argv."""
import http.cookiejar
import json
import math
import re
import sys
import time
import os

try:
    os.nice(10)  # Yield CPU to the headset's render and browser threads.
except (AttributeError, OSError):  # No nice() on Windows host tests.
    pass
from urllib.parse import urlsplit
from urllib.parse import urljoin
from html.parser import HTMLParser

SESSION_GROUPS = (("youtube.com",), ("bilibili.com",), ("douyin.com", "iesdouyin.com"),
                  ("weibo.com", "weibo.cn"), ("iqiyi.com",), ("mgtv.com",), ("qq.com",),
                  ("youku.com",), ("vimeo.com",), ("dailymotion.com", "dai.ly"),
                  ("twitch.tv",), ("tubitv.com",), ("redbull.com", "redbull.tv"), ("astalavr.com",),
                  ("tiktok.com",), ("instagram.com",), ("facebook.com", "fb.watch"),
                  ("twitter.com", "x.com"), ("reddit.com", "redd.it"), ("streamable.com",),
                  ("ted.com",), ("archive.org",), ("rumble.com",), ("odysee.com",),
                  ("nicovideo.jp", "nico.ms"), ("naver.com",), ("kakao.com",))


class SpatialHtmlParser(HTMLParser):
    """Read declared player sources; never execute a site's player or challenge code."""
    def __init__(self, page):
        super().__init__()
        self.page, self.players, self.active = page, [], None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "dl8-video":
            self.active = {"title": attrs.get("title", "Video"), "formats": [], "layout": attrs.get("format", "")}
            self.players.append(self.active)
        elif tag == "source" and self.active is not None and len(self.active["formats"]) < 32:
            url = urljoin(self.page, attrs.get("src", ""))
            kind = attrs.get("type", "")
            if urlsplit(url).scheme not in ("http", "https") or kind not in ("video/mp4", "video/webm", "application/x-mpegurl", "application/vnd.apple.mpegurl"):
                return
            self.active["formats"].append({"format_id": str(len(self.active["formats"])), "url": url,
                "ext": "webm" if kind == "video/webm" else "mp4", "vcodec": "unknown", "acodec": "unknown",
                "protocol": "m3u8_native" if "mpegurl" in kind else urlsplit(url).scheme,
                "web_layout": attrs.get("format", self.active["layout"]), "quality": -len(self.active["formats"]),
                "http_headers": {"Referer": self.page}})

    def handle_endtag(self, tag):
        if tag == "dl8-video":
            self.active = None


def add_spatial_extractor(ydl):
    from yt_dlp.extractor.common import InfoExtractor
    class SpatialPageIE(InfoExtractor):
        _VALID_URL = r"https?://(?:www\.)?astalavr\.com/videos?/(?P<id>[A-Za-z0-9_-]+)(?:/[^?#]*)?"
        def _real_extract(self, url):
            video_id = self._match_id(url)
            parser = SpatialHtmlParser(url)
            parser.feed(self._download_webpage(url, video_id))
            playable = [p for p in parser.players if p["formats"]]
            if len(playable) != 1:
                raise ValueError("Choose an individual video page")
            return {"id": video_id, "title": playable[0]["title"], "formats": playable[0]["formats"]}
    ydl.add_info_extractor(SpatialPageIE())


def load_cookies(jar, items, page_url):
    host = urlsplit(page_url).hostname or ""
    roots = next((g for g in SESSION_GROUPS if any(host == d or host.endswith("." + d) for d in g)), ())
    if not roots or not isinstance(items, list) or len(items) > 256:
        raise ValueError("Invalid session scope")
    jar.set_policy(http.cookiejar.DefaultCookiePolicy(
        strict_ns_domain=http.cookiejar.DefaultCookiePolicy.DomainStrictNonDomain))
    for item in items:
        if not isinstance(item, dict):
            continue
        domain = str(item.get("domain", "")).lower()
        bare = domain.lstrip(".")
        name, value, path = (item.get(k, "") for k in ("name", "value", "path"))
        if (not re.fullmatch(r"[a-z0-9.-]+", domain) or not any(bare == root or bare.endswith("." + root) for root in roots)
                or not isinstance(name, str) or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9a-zA-Z-]{1,256}", name)
                or not isinstance(value, str) or len(value) > 8192 or any(ord(c) < 32 or ord(c) > 126 or c == ";" for c in value)
                or not isinstance(path, str) or not path.startswith("/") or len(path) > 2048):
            continue
        expires = item.get("expirationDate")
        if expires is not None:
            if not isinstance(expires, (int, float)) or not math.isfinite(expires) or expires <= time.time():
                continue
            expires = int(expires)
        host_only = item.get("hostOnly") is True
        if host_only and domain.startswith("."):
            continue
        jar.set_cookie(http.cookiejar.Cookie(
            version=0, name=name, value=value, port=None, port_specified=False,
            domain=bare if host_only else "." + bare, domain_specified=not host_only,
            domain_initial_dot=not host_only, path=path, path_specified=True,
            secure=item.get("secure") is True, expires=expires, discard=expires is None,
            comment=None, comment_url=None, rest={"HttpOnly": None} if item.get("httpOnly") else {}))


def scope_headers(info, jar):
    # yt-dlp's serialized `cookies` field is not an HTTP Cookie header.
    # Remove inherited credentials and derive a separate header for every actual URL.
    info.pop("cookies", None)
    info["http_headers"] = {k: v for k, v in info.get("http_headers", {}).items() if k.lower() != "cookie"}
    for item in info.get("formats", []):
        item.pop("cookies", None)
        headers = {k: v for k, v in item.get("http_headers", {}).items() if k.lower() != "cookie"}
        url = item.get("url", "")
        if urlsplit(url).scheme in ("http", "https"):
            cookie = jar.get_cookie_header(url)
            if cookie:
                headers["Cookie"] = cookie
        item["http_headers"] = headers


def bilibili_cdn_formats(formats, play_info):
    """Preserve the site's own backup URLs; never invent a CDN host or reuse a signature."""
    if play_info.get("is_preview") or play_info.get("is_trial"):
        raise ValueError("Bilibili preview requires browser playback")
    if play_info.get("is_drm") or play_info.get("has_drm") or play_info.get("drm_tech_type"):
        raise ValueError("Bilibili DRM requires browser playback")
    dash = play_info.get("dash") or {}
    representations = list(dash.get("video") or []) + list(dash.get("audio") or [])
    representations += list((dash.get("dolby") or {}).get("audio") or [])
    flac = (dash.get("flac") or {}).get("audio")
    if isinstance(flac, dict):
        representations.append(flac)
    result = list(formats)
    for f in formats:
        for representation in representations:
            if f.get("url") != (representation.get("baseUrl") or representation.get("base_url") or representation.get("url")):
                continue
            backups = representation.get("backupUrl") or representation.get("backup_url") or []
            for index, url in enumerate(backups[:8]):
                if isinstance(url, str) and urlsplit(url).scheme in ("http", "https"):
                    result.append(dict(f, url=url, format_id=str(f.get("format_id", "")) + "-cdn" + str(index)))
    return result


def single_video(info):
    # A post with several videos is not one silently interchangeable media identity.
    if info.get("_type") in ("playlist", "multi_video"):
        entries = [entry for entry in info.get("entries", []) if entry]
        if len(entries) != 1:
            raise ValueError("Choose an individual video page")
        return entries[0]
    return info


def normalize_manifests(info, ydl):
    """Expand site-supplied master playlists, keeping real metadata and credentials."""
    from yt_dlp.extractor.common import InfoExtractor
    ie = InfoExtractor(ydl)
    formats = []
    for item in info.get("formats", []):
        if item.get("protocol") not in ("m3u8", "m3u8_native") or item.get("has_drm"):
            formats.append(item)
            continue
        headers = {**info.get("http_headers", {}), **item.get("http_headers", {})}
        expanded = ie._extract_m3u8_formats(item["url"], info.get("id", "video"), "mp4",
                                           m3u8_id=str(item.get("format_id", "hls")), fatal=False, headers=headers)
        for child in expanded or [item]:
            merged = {**item, **{k: v for k, v in child.items() if v is not None}}
            merged["http_headers"] = headers
            # Unknown is deliberately left unknown, never invented as H.264/1080p.
            formats.append(merged)
        if len(formats) > 4096:
            raise ValueError("Too many formats")
    info["formats"] = formats
    return info


def retry_transport(ydl):
    """Resend only the request a headset network path cut, spaced past the cut.

    Quest 3 (2026-10-29): Niconico failed 4 of 10 sandbox runs on TLS EOF; the cuts come in
    bursts (two whole-extraction attempts 0.6 s apart both failed), so redoing everything at once
    hits the same burst while repeating the site's access-rights request.
    """
    from yt_dlp.networking.exceptions import CertificateVerifyError, ProxyError, TransportError
    urlopen = ydl.urlopen

    def patient(req):
        for attempt in range(3):
            started = time.monotonic()
            try:
                return urlopen(req)
            except (CertificateVerifyError, ProxyError):
                raise
            except TransportError:
                # A request that already waited out the socket timeout is not a short cut.
                if attempt == 2 or time.monotonic() - started > 10:
                    raise
                time.sleep(2.0 * (attempt + 1))
    ydl.urlopen = patient


def main():
    runtime, quickjs, page = sys.argv[1:]
    sys.path.insert(0, runtime)
    from yt_dlp import YoutubeDL
    from yt_dlp.globals import plugin_dirs
    from yt_dlp.extractor.bilibili import BilibiliBaseIE
    original_formats = BilibiliBaseIE.extract_formats
    BilibiliBaseIE.extract_formats = lambda self, data: bilibili_cdn_formats(original_formats(self, data), data)
    plugin_dirs.value = []
    payload = sys.stdin.buffer.read(256 * 1024 + 1)
    if len(payload) > 256 * 1024:
        raise ValueError("Session too large")
    cookies = json.loads(payload)
    del payload
    # Measured on Quest 3 (2026-10-28): enabling yt-dlp's preprocessed-player cache left a cold
    # YouTube resolution at 22-24 s, so the network round trips dominate; keep upstream's default.
    cache = False
    options = dict(quiet=True, no_warnings=True, noprogress=True, cachedir=cache,
                   noplaylist=True, skip_download=True, socket_timeout=15, retries=1,
                   extractor_retries=1, js_runtimes={"quickjs": {"path": quickjs}})
    with YoutubeDL(options, auto_init=False) as ydl:
        add_spatial_extractor(ydl)
        ydl.add_default_info_extractors()
        retry_transport(ydl)
        load_cookies(ydl.cookiejar, cookies, page)
        cookies.clear()
        if urlsplit(page).hostname == "v.douyin.com":
            with ydl.urlopen(page) as response:
                target = response.url
            parts = urlsplit(target)
            match = re.search(r"/(?:share/)?video/([0-9]{8,24})(?:/|$)", parts.path)
            if parts.hostname not in ("www.douyin.com", "douyin.com", "www.iesdouyin.com", "iesdouyin.com") or not match:
                raise ValueError("Invalid share redirect")
            page = "https://www.douyin.com/video/" + match.group(1)
        # Some headset network paths intermittently cut TLS mid-handshake (seen on Quest 3 for
        # Streamable/Odysee/Archive.org: 2 of 3 runs). Metadata requests are not retried by
        # yt-dlp itself. retry_transport resends a cut request; this outer pass covers a cut while
        # a response body is read, spaced past the burst, within the caller's deadline.
        from yt_dlp.utils import DownloadError
        for attempt in range(3):
            try:
                extracted = ydl.extract_info(page, download=False)
                break
            except DownloadError as error:
                transient = any(term in str(error) for term in ("SSL:", "EOF occurred", "Connection reset", "timed out", "Remote end closed"))
                if attempt == 2 or not transient:
                    raise
                time.sleep(2.0 * (attempt + 1))
        info = normalize_manifests(single_video(extracted), ydl)
        scope_headers(info, ydl.cookiejar)
        # Never return requested_formats/cookie jars or unrelated extractor internals.
        keys = ("id", "title", "duration", "is_live", "live_status", "has_drm", "formats", "http_headers", "webpage_url")
        result = {k: info[k] for k in keys if k in info}
        print(json.dumps(ydl.sanitize_info(result), ensure_ascii=False))


if __name__ == "__main__":
    main()
