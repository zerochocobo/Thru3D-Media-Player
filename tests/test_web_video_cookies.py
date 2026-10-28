import importlib.util
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("extract", ROOT / "android/player-plugin/src/main/assets/web-video/extract.py")
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
sys.path.insert(0, str(ROOT / "build/web-video/yt-dlp.zip"))
from yt_dlp.cookies import YoutubeDLCookieJar


class CookieBoundaryTest(unittest.TestCase):
    def test_declared_player_sources_keep_layout_without_inventing_dimensions(self):
        parser = extract.SpatialHtmlParser("https://example.test/videos/demo")
        parser.feed('<dl8-video title="Example" format="STEREO_180_LR"><source src="/movie.mp4" type="video/mp4" quality="4K"><source src="//cdn.test/next.mp4" type="video/mp4"><source src="javascript:bad" type="video/mp4"></dl8-video><source src="/outside.mp4" type="video/mp4">')
        self.assertEqual(1, len(parser.players))
        formats = parser.players[0]["formats"]
        self.assertEqual(2, len(formats))
        self.assertEqual("https://example.test/movie.mp4", formats[0]["url"])
        self.assertEqual("STEREO_180_LR", formats[0]["web_layout"])
        self.assertNotIn("width", formats[0])
        self.assertGreater(formats[0]["quality"], formats[1]["quality"])

    def test_paired_weibo_login_does_not_include_unrelated_account_domains(self):
        jar = YoutubeDLCookieJar()
        items = [dict(self.cookie(), domain=domain, hostOnly=False) for domain in (".weibo.com", ".weibo.cn", ".qq.com", ".weibo.com.evil.test")]
        extract.load_cookies(jar, items, "https://m.weibo.cn/detail/123")
        self.assertEqual("session=synthetic", jar.get_cookie_header("https://weibo.com/ajax/statuses/show"))
        self.assertEqual("session=synthetic", jar.get_cookie_header("https://m.weibo.cn/detail/123"))
        self.assertIsNone(jar.get_cookie_header("https://qq.com/"))
        self.assertIsNone(jar.get_cookie_header("https://weibo.com.evil.test/"))

    def test_cookie_groups_match_extension_permissions_and_native_registry(self):
        root = ROOT / "android/web-browser/src/main"
        manifest = json.loads((root / "assets/web-browser/manifest.json").read_text())
        native = (root / "java/org/vrpassthroughplayer/plugin/WebVideoSessionScope.kt").read_text()
        background = (root / "assets/web-browser/background.js").read_text()
        for group in extract.SESSION_GROUPS:
            for domain in group:
                self.assertIn("https://*." + domain + "/*", manifest["permissions"])
                self.assertIn('"' + domain + '"', native)
                self.assertIn('"' + domain + '"', background)

    def test_multivideo_posts_require_an_individual_video(self):
        one = {"formats": []}
        self.assertIs(one, extract.single_video({"_type": "playlist", "entries": [one]}))
        with self.assertRaises(ValueError):
            extract.single_video({"_type": "playlist", "entries": [one, one]})

    def test_bilibili_keeps_site_backups_and_scopes_credentials_to_each_host(self):
        primary = "https://node.mcdn.bilivideo.cn/video.m4s?signature=synthetic"
        backup = "https://upos-sz-test.bilivideo.com/video.m4s?signature=different"
        formats = [{"url": primary, "format_id": "30080", "width": 1920, "height": 1080}]
        extended = extract.bilibili_cdn_formats(formats, {"dash": {"video": [{"baseUrl": primary,
            "backupUrl": [backup, "file:///invalid"]}], "audio": []}})
        self.assertEqual(2, len(extended))
        self.assertEqual(backup, extended[1]["url"])
        self.assertEqual(1080, extended[1]["height"])
        self.assertEqual(primary, formats[0]["url"])
        jar = YoutubeDLCookieJar()
        extract.load_cookies(jar, [{**self.cookie(), "domain": ".bilibili.com"}], "https://www.bilibili.com/video/BV13x41117TL/")
        info = {"formats": extended}
        extract.scope_headers(info, jar)
        self.assertTrue(all("Cookie" not in f["http_headers"] for f in extended))

    def cookie(self, **kw):
        return dict(name="session", value="synthetic", domain=".youtube.com", path="/", secure=True, hostOnly=False, **kw)

    def test_domain_path_secure_host_only_and_expiry(self):
        jar = YoutubeDLCookieJar()
        items = [self.cookie(), {**self.cookie(), "name": "private", "path": "/private"},
                 {**self.cookie(), "name": "host", "domain": "www.youtube.com", "hostOnly": True},
                 {**self.cookie(), "name": "expired", "expirationDate": 1},
                 {**self.cookie(), "name": "alien", "domain": ".bilibili.com"},
                 {**self.cookie(), "name": "suffix", "domain": ".youtube.com.evil.test"},
                 {**self.cookie(), "name": "inject", "value": "x\r\nHeader: value"}]
        extract.load_cookies(jar, items, "https://www.youtube.com/watch?v=jNQXAC9IVRw")
        self.assertEqual("session=synthetic; host=synthetic", jar.get_cookie_header("https://www.youtube.com/watch"))
        self.assertEqual("session=synthetic", jar.get_cookie_header("https://sub.www.youtube.com/watch"))
        self.assertIn("private=synthetic", jar.get_cookie_header("https://www.youtube.com/private/video"))
        for url in ("http://www.youtube.com/watch", "https://youtube.com.evil.test/", "https://video.googlevideo.com/", "https://bilibili.com/"):
            self.assertIsNone(jar.get_cookie_header(url), url)

    def test_credentials_are_per_format_never_common(self):
        jar = YoutubeDLCookieJar()
        extract.load_cookies(jar, [self.cookie()], "https://www.youtube.com/watch")
        info = {"url": "https://www.youtube.com/a", "http_headers": {"Cookie": "stale", "User-Agent": "test"},
                "formats": [{"url": url, "http_headers": {"cookie": "stale"}, "cookies": "serialized"}
                            for url in ("https://www.youtube.com/a", "https://video.googlevideo.com/a")]}
        extract.scope_headers(info, jar)
        self.assertNotIn("Cookie", info["http_headers"])
        self.assertEqual("session=synthetic", info["formats"][0]["http_headers"]["Cookie"])
        self.assertEqual({}, info["formats"][1]["http_headers"])
        self.assertNotIn("serialized", json.dumps(info))


if __name__ == "__main__":
    unittest.main()
