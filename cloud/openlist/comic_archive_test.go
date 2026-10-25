package cloudcore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/bodgit/sevenzip"
	"github.com/gin-gonic/gin"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func comicFixture(t *testing.T, name string) (*comicSource, *int64) {
	t.Helper()
	root := os.Getenv("COMIC_FIXTURES")
	if root == "" {
		t.Skip("Run tools/Generate-ComicFixtures.py and set COMIC_FIXTURES")
	}
	data, e := os.ReadFile(filepath.Join(root, name))
	if e != nil {
		t.Fatal(e)
	}
	var sent int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sent++
		http.ServeContent(w, r, name, time.Unix(1, 0), bytes.NewReader(data))
	}))
	t.Cleanup(server.Close)
	s, e := newComicSource(context.Background(), server.URL)
	if e != nil {
		t.Fatal(e)
	}
	return s, &sent
}
func TestComicFormatsPasswordsAndRandomPages(t *testing.T) {
	for _, name := range []string{"plain.zip", "store.cbz", "zipcrypto.zip", "aes.zip", "plain.rar", "encrypted.rar", "quickopen.rar", "quickopen-encrypted-data.rar", "plain.7z", "encrypted.7z", "encrypted-data.7z"} {
		t.Run(name, func(t *testing.T) {
			s, _ := comicFixture(t, name)
			pass := ""
			if name == "zipcrypto.zip" || name == "aes.zip" || name == "encrypted.rar" || name == "quickopen-encrypted-data.rar" || name == "encrypted.7z" || name == "encrypted-data.7z" {
				pass = "comic-test"
			}
			c, e := comicIndex(s, name, pass)
			if e != nil {
				t.Fatal(e)
			}
			c.dir = t.TempDir()
			if len(c.pages) != 3 || c.pages[0].Name != "1.png" || c.pages[1].Name != "2.png" || c.pages[2].Name != "10.png" {
				t.Fatal("natural page order", c.pages)
			}
			for _, index := range []int{2, 0, 1, 2} {
				p, e := c.page(index)
				if e != nil {
					t.Fatal(e)
				}
				data, e := os.ReadFile(p)
				if e != nil || !bytes.HasPrefix(data, []byte("\x89PNG")) {
					t.Fatal("bad extracted page", e)
				}
			}
			before := s.reads
			if _, e := c.page(1); e != nil || s.reads != before {
				t.Fatal("cached page fetched again", e)
			}
		})
	}
}
func TestComicRejectsSolidAndWrongPasswords(t *testing.T) {
	for _, name := range []string{"solid.rar", "solid.7z"} {
		t.Run(name, func(t *testing.T) {
			s, _ := comicFixture(t, name)
			_, e := comicIndex(s, name, "")
			if !errors.Is(e, errComicSolid) {
				t.Fatal("expected solid rejection", e)
			}
		})
	}
	for _, name := range []string{"zipcrypto.zip", "aes.zip", "encrypted.rar", "quickopen-encrypted-data.rar", "encrypted.7z", "encrypted-data.7z"} {
		t.Run(name, func(t *testing.T) {
			s, _ := comicFixture(t, name)
			c, e := comicIndex(s, name, "wrong")
			if e == nil {
				c.dir = t.TempDir()
				_, e = c.page(0)
			}
			if e == nil {
				t.Fatal("wrong password accepted")
			}
			if comicError(e, "wrong") != errComicPassword.Error() {
				t.Fatalf("password prompt lost: %v", e)
			}
		})
	}
}

func TestComicSessionLifecycle(t *testing.T) {
	s, sent := comicFixture(t, "aes.zip")
	api := gin.New()
	comicRoutes(api)
	call := func(body map[string]any) map[string]any {
		data, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		api.ServeHTTP(w, httptest.NewRequest("POST", "/comic", bytes.NewReader(data)))
		var result struct {
			Data map[string]any `json:"data"`
		}
		if e := json.Unmarshal(w.Body.Bytes(), &result); e != nil {
			t.Fatal(e)
		}
		return result.Data
	}
	cache := t.TempDir()
	request := map[string]any{"op": "open", "url": s.url, "name": "book.zip", "cache": cache, "password": "wrong"}
	bad := call(request)
	if bad["error"] != errComicPassword.Error() || len(comicSessions) != 0 {
		t.Fatal(bad)
	}
	reads := *sent
	request["password"] = "comic-test"
	good := call(request)
	if good["error"] != nil || good["verified"] != true {
		t.Fatal(good)
	}
	if *sent != reads {
		t.Fatal("password retry discarded cached encrypted bytes")
	}
	key := good["session"].(string)
	page := call(map[string]any{"op": "page", "session": key, "page": 2})
	if page["error"] != nil {
		t.Fatal(page)
	}
	filename := page["path"].(string)
	if !strings.HasPrefix(filename, cache) {
		t.Fatal("page escaped cache")
	}
	call(map[string]any{"op": "close", "session": key})
	if _, e := os.Stat(filename); !os.IsNotExist(e) {
		t.Fatal("closed session left plaintext pages", e)
	}
	if late := call(map[string]any{"op": "page", "session": key, "page": 2}); late["error"] == nil {
		t.Fatal("closed capability accepted")
	}
	// Cancellation can lose the newly returned key; the foreground bridge must
	// still be able to remove the resulting session and its extracted pages.
	opened := call(request)
	if opened["error"] != nil {
		t.Fatal(opened)
	}
	call(map[string]any{"op": "close", "session": ""})
	if len(comicSessions) != 0 {
		t.Fatal("cancelled open left an orphaned comic session")
	}

}

func TestComicCorruptionIsNotPublished(t *testing.T) {
	for _, name := range []string{"store.cbz", "plain.7z"} {
		t.Run(name, func(t *testing.T) {
			s, _ := comicFixture(t, name)
			c, e := comicIndex(s, name, "")
			if e != nil {
				t.Fatal(e)
			}
			c.dir = t.TempDir()
			if name == "store.cbz" {
				if e = c.pages[0].prime(); e != nil {
					t.Fatal(e)
				}
				changed := false
				for _, block := range s.blocks {
					if i := bytes.Index(block.data, []byte("\x89PNG")); i >= 0 {
						block.data[i] ^= 1
						changed = true
						break
					}
				}
				if !changed {
					t.Fatal("fixture payload not cached")
				}
			} else {
				// sevenzip exposes CRC but its File.Open does not check page content.
				original := c.pages[0].open
				c.pages[0].open = func() (io.ReadCloser, error) {
					r, e := original()
					if e != nil {
						return nil, e
					}
					data, e := io.ReadAll(r)
					r.Close()
					if e != nil {
						return nil, e
					}
					data[0] ^= 1
					return io.NopCloser(bytes.NewReader(data)), nil
				}
			}
			if _, e = c.page(0); e == nil {
				t.Fatal("corrupt page accepted")
			}
			files, _ := os.ReadDir(c.dir)
			if len(files) != 0 {
				t.Fatal("corrupt plaintext published")
			}
		})
	}
}

func TestComicRangeAndCancellation(t *testing.T) {
	for _, reason := range []error{errComicBusy, errComicRange, context.Canceled} {
		wrapped := &sevenzip.ReadError{Encrypted: true, Err: reason}
		if comicError(wrapped, "") == errComicPassword.Error() {
			t.Fatal("transport failure misreported as password error", reason)
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(bytes.Repeat([]byte{1}, 64)) }))
	defer server.Close()
	if _, e := newComicSource(context.Background(), server.URL); e == nil {
		t.Fatal("ignored range accepted")
	}
	s, _ := comicFixture(t, "plain.zip")
	ctx, cancel := context.WithCancel(context.Background())
	s.ctx = ctx
	cancel()
	if _, e := s.ReadAt(make([]byte, 1), 0); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	if _, e := newComicSource(context.Background(), "https://example.com/archive.zip"); e == nil {
		t.Fatal("external URL bypassed Android source")
	}
}

func TestComicManagementGateAndCancelledTicket(t *testing.T) {
	previous := api
	api = nil
	defer func() { api = previous }()
	requestMu <- struct{}{}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	_, e := requestContext(ctx, "POST", "/comic", `{"op":"close"}`)
	cancel()
	<-requestMu
	if errors.Is(e, context.DeadlineExceeded) {
		t.Fatal("comic shares cloud management gate; source resolution can deadlock")
	}
	key, e := NewRequest()
	if e != nil {
		t.Fatal(e)
	}
	CancelRequest(key)
	if _, e = RequestCancelable("POST", "/comic", `{"op":"close"}`, key); e == nil {
		t.Fatal("comic resurrected cancelled request")
	}
}
func TestComicLargeUserSampleOptional(t *testing.T) {
	filename := os.Getenv("COMIC_LARGE_SAMPLE")
	if filename == "" {
		t.Skip("Optional read-only user sample")
	}
	file, e := os.Open(filename)
	if e != nil {
		t.Fatal(e)
	}
	defer file.Close()
	stat, _ := file.Stat()
	name := "sample" + strings.ToLower(filepath.Ext(filename))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, e := os.Open(filename)
		if e != nil {
			t.Error(e)
			return
		}
		defer f.Close()
		http.ServeContent(w, r, name, stat.ModTime(), f)
	}))
	defer server.Close()
	s, e := newComicSource(context.Background(), server.URL)
	if e != nil {
		t.Fatal(e)
	}
	s.remote = true // Apply cloud index budgets and request pacing to real samples.
	c, e := comicIndex(s, name, "")
	if e != nil {
		t.Fatalf("index: %v ranges=%d bytes=%d", e, s.reads, s.bytes)
	}
	c.dir = t.TempDir()
	// Real directories vary in size; enforce the production remote budgets.
	// Synthetic tests separately assert that indexing never fetches page data.
	t.Logf("size=%d entries=%d pages=%d quick_open_records=%d index_ranges=%d index_bytes=%d", stat.Size(), len(c.entries), len(c.pages), len(s.rarHeaders), s.reads, s.bytes)
	for _, i := range []int{0, 1, len(c.pages) / 2, len(c.pages) - 1} {
		if _, e := c.page(i); e != nil {
			t.Fatal(e)
		}
	}
	reads := s.reads
	for _, i := range []int{len(c.pages) - 1, len(c.pages) / 2, len(c.pages) - 1} {
		if _, e := c.page(i); e != nil || s.reads != reads {
			t.Fatal("revisited sample page fetched again", e)
		}
	}
	t.Logf("pages=%d range_reads=%d bytes=%d", len(c.pages), s.reads, s.bytes)
}

// The JVM fixture serves a completed production SmallRarCache through the real
// LocalStreamServer. A completed cache is classified local by ArchiveBridge.
func TestComicCachedLoopbackOptional(t *testing.T) {
	address := os.Getenv("COMIC_CACHED_LOOPBACK")
	if address == "" {
		t.Skip("Optional JVM cache-to-decoder integration")
	}
	started := time.Now()
	s, e := newComicSource(context.Background(), address)
	if e != nil {
		t.Fatal(e)
	}
	c, e := comicIndex(s, "sample.rar", "")
	if e != nil {
		t.Fatal(e)
	}
	if len(c.pages) == 0 {
		t.Fatal("Cached RAR has no image pages")
	}
	t.Logf("cached index: entries=%d pages=%d local_ranges=%d local_bytes=%d elapsed_ms=%d", len(c.entries), len(c.pages), s.reads, s.bytes, time.Since(started).Milliseconds())
	c.dir = t.TempDir()
	for _, i := range []int{0, 1, len(c.pages) / 2, len(c.pages) - 1} {
		if _, e := c.page(i); e != nil {
			t.Fatal(e)
		}
	}
	reads := s.reads
	for _, i := range []int{len(c.pages) - 1, len(c.pages) / 2} {
		if _, e := c.page(i); e != nil || s.reads != reads {
			t.Fatal("Cached page reread contacted source", e)
		}
	}
	t.Logf("cached index and four CRC-verified pages: elapsed_ms=%d", time.Since(started).Milliseconds())
}
