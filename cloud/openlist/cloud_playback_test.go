package cloudcore

import (
	"bytes"
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/conf"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/errs"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	cloudnet "github.com/OpenListTeam/OpenList/v4/internal/net"
	"github.com/gin-gonic/gin"
	pkgerrors "github.com/pkg/errors"
)

type playbackProxyFixture struct {
	deletionFixture
	origin     string
	links      atomic.Int32
	rotating   bool
	expiration *time.Duration
	partSize   int
}

func (d *playbackProxyFixture) Get(context.Context, string) (model.Obj, error) {
	panic("proxy re-entered generic Getter / 8000-row full-directory fallback")
}
func (d *playbackProxyFixture) List(context.Context, model.Obj, model.ListArgs) ([]model.Obj, error) {
	panic("proxy enumerated a directory")
}
func (d *playbackProxyFixture) Link(_ context.Context, obj model.Obj, args model.LinkArgs) (*model.Link, error) {
	if args.Header.Get("X-Thru3D-Archive-Read") != "" {
		return nil, errors.New("internal archive policy reached provider")
	}
	if obj.GetID() != "9" || obj.ModTime().Unix() != 0 || args.Header.Get("User-Agent") != "fixture-player" {
		return nil, errors.New("wrong identity or user agent")
	}
	ticket := d.links.Add(1)
	origin := d.origin
	if d.rotating {
		origin += "?ticket=" + strconv.Itoa(int(ticket))
	}
	link := &model.Link{URL: origin, Header: http.Header{"User-Agent": []string{"provider-agent"}}, Expiration: d.expiration}
	if d.partSize > 0 {
		link.Concurrency, link.PartSize = 3, d.partSize
	}
	return link, nil
}

func TestBoundPlaybackProxyColdRangesUseOnlySelectedIdentityEvenWithoutTimestamp(t *testing.T) {
	previousConfig := conf.Conf
	conf.Conf = conf.DefaultConfig(t.TempDir())
	t.Cleanup(func() { conf.Conf = previousConfig })
	payload := bytes.Repeat([]byte("0123456789abcdef"), 1024)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "provider-agent" {
			t.Error("provider user agent missing")
		}
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	d := &playbackProxyFixture{origin: upstream.URL}
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	oldBase := streamBase
	streamBase = "http://127.0.0.1:1/capability"
	t.Cleanup(func() { streamBase = oldBase })
	file := &model.Object{ID: "9", Name: "电影 #%.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	location, err := playbackLeaseURL(d, d.MountPath, "/V/"+file.Name, file)
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(location)
	engine := gin.New()
	handler := func(c *gin.Context) {
		servePlayback115(c, func(path string) (driver.Driver, string, error) {
			if path != d.MountPath+"/V/"+file.Name {
				return nil, "", errors.New("wrong mount/path")
			}
			return d, "/V/" + file.Name, nil
		})
	}
	engine.GET("/capability-115/:lease/*name", handler)
	engine.HEAD("/capability-115/:lease/*name", handler)
	for _, tc := range []struct {
		method, span string
		code         int
		want         []byte
	}{
		{"HEAD", "", 200, nil}, {"GET", "bytes=42-103", 206, payload[42:104]}, {"GET", "bytes=-16", 206, payload[len(payload)-16:]},
	} {
		r := httptest.NewRequest(tc.method, u.RequestURI(), nil)
		r.Header.Set("User-Agent", "fixture-player")
		if tc.span != "" {
			r.Header.Set("Range", tc.span)
		}
		w := httptest.NewRecorder()
		engine.ServeHTTP(w, r)
		body, _ := io.ReadAll(w.Result().Body)
		if w.Code != tc.code || !bytes.Equal(body, tc.want) {
			t.Fatal(tc.method, tc.span, w.Code, len(body))
		}
	}
	if d.links.Load() != 1 || len(d.reads) != 0 || len(d.writes) != 0 {
		t.Fatal(d.links.Load(), d.reads, d.writes)
	}
	bad := httptest.NewRecorder()
	engine.ServeHTTP(bad, httptest.NewRequest("GET", strings.Replace(u.RequestURI(), "%E7%94%B5%E5%BD%B1", "other", 1), nil))
	if bad.Code != 404 {
		t.Fatal("unbound filename accepted", bad.Code)
	}
}

func playbackRecoveryHandler(t *testing.T, d *playbackProxyFixture, file model.Obj) (http.Handler, string, *cloudPlaybackLease) {
	t.Helper()
	previousConfig := conf.Conf
	conf.Conf = conf.DefaultConfig(t.TempDir())
	oldBase := streamBase
	streamBase = "http://127.0.0.1:1/recovery"
	t.Cleanup(func() { conf.Conf = previousConfig; streamBase = oldBase })
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	location, err := playbackLeaseURL(d, d.MountPath, "/film.mp4", file)
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(location)
	key := strings.Split(strings.TrimPrefix(u.Path, "/recovery-115/"), "/")[0]
	cloudPlaybackLeases.Lock()
	lease := cloudPlaybackLeases.items[key]
	cloudPlaybackLeases.Unlock()
	t.Cleanup(func() {
		cloudPlaybackLeases.Lock()
		delete(cloudPlaybackLeases.items, key)
		cloudPlaybackLeases.Unlock()
	})
	engine := gin.New()
	engine.GET("/recovery-115/:lease/*name", func(c *gin.Context) {
		servePlayback115(c, func(string) (driver.Driver, string, error) { return d, "/film.mp4", nil })
	})
	return engine, u.RequestURI(), lease
}

func playbackRecoveryRequest(handler http.Handler, uri string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("GET", uri, nil)
	r.Header.Set("User-Agent", "fixture-player")
	r.Header.Set("Range", "bytes=42-103")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func TestPlaybackExpiredLinkStatusReachesClientAndNextReadGetsFreshLink(t *testing.T) {
	for _, status := range []int{401, 403, 410} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/expired" {
					w.WriteHeader(status)
					_, _ = w.Write([]byte("private error body"))
					return
				}
				if r.Header.Get("User-Agent") != "provider-agent" || r.Header.Get("Range") != "bytes=42-103" {
					t.Error("range or user agent lost")
				}
				http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
			}))
			defer upstream.Close()
			d := &playbackProxyFixture{origin: upstream.URL + "/expired"}
			file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
			handler, uri, lease := playbackRecoveryHandler(t, d, file)
			failed := playbackRecoveryRequest(handler, uri)
			if failed.Code != status || failed.Body.Len() != 0 {
				t.Fatal("lost status or leaked upstream body", failed.Code, failed.Body.Len())
			}
			if len(lease.links) != 0 {
				t.Fatal("expired download link retained")
			}
			d.origin = upstream.URL + "/valid"
			recovered := playbackRecoveryRequest(handler, uri)
			if recovered.Code != 206 || !bytes.Equal(recovered.Body.Bytes(), payload[42:104]) || d.links.Load() != 2 {
				t.Fatal("fresh link did not recover exact range", recovered.Code, d.links.Load())
			}
		})
	}
}

// Quark: one connection is throttled; its driver asks for parallel ranged parts.
func TestPlaybackLeaseKeepsProviderRangedPartsAcrossCachedReads(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "provider-agent" {
			t.Error("provider header lost")
		}
		requests.Add(1)
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	d := &playbackProxyFixture{origin: upstream.URL, partSize: 16}
	file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	handler, uri, _ := playbackRecoveryHandler(t, d, file)
	for read := 1; read <= 2; read++ {
		before := requests.Load()
		w := playbackRecoveryRequest(handler, uri)
		if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), payload[42:104]) {
			t.Fatal("parted read lost the exact range", read, w.Code)
		}
		if requests.Load()-before != 4 {
			t.Fatal("62 bytes in 16-byte parts must take four upstream ranges", read, requests.Load()-before)
		}
	}
	if d.links.Load() != 1 {
		t.Fatal("second read did not reuse the cached ticket", d.links.Load())
	}
}

func TestPlaybackPartedFailureDropsTicketSoTheRetryRecovers(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/expired" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte("private error body"))
			return
		}
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	d := &playbackProxyFixture{origin: upstream.URL + "/expired", partSize: 16}
	file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	handler, uri, lease := playbackRecoveryHandler(t, d, file)
	w := playbackRecoveryRequest(handler, uri)
	if w.Code < 400 || w.Body.Len() != 0 || w.Header().Get("Content-Length") != "" || len(lease.links) != 0 {
		t.Fatal("parted failure leaked a body or kept the ticket", w.Code, w.Body.Len(), len(lease.links))
	}
	d.origin = upstream.URL + "/valid"
	recovered := playbackRecoveryRequest(handler, uri)
	if recovered.Code != 206 || !bytes.Equal(recovered.Body.Bytes(), payload[42:104]) || d.links.Load() != 2 {
		t.Fatal("retry did not recover with a fresh ticket", recovered.Code, d.links.Load())
	}
}

func TestPlaybackGatewayStatusIsPreservedWithoutDiscardingAValidLink(t *testing.T) {
	for _, status := range []int{404, 416, 500, 502, 503, 504} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
			defer upstream.Close()
			d := &playbackProxyFixture{origin: upstream.URL}
			file := &model.Object{ID: "9", Name: "film.mp4", Size: 1000, Modified: time.Unix(0, 0)}
			handler, uri, lease := playbackRecoveryHandler(t, d, file)
			for i := 0; i < 2; i++ {
				w := playbackRecoveryRequest(handler, uri)
				if w.Code != status || w.Body.Len() != 0 {
					t.Fatal("wrong status", w.Code)
				}
			}
			if len(lease.links) != 1 || d.links.Load() != 1 {
				t.Fatal("gateway retry unnecessarily resolved provider link")
			}
		})
	}
}

func TestPlaybackIdleLinkRefreshKeepsObjectAndRange(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	d := &playbackProxyFixture{origin: upstream.URL}
	file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	handler, uri, lease := playbackRecoveryHandler(t, d, file)
	if playbackRecoveryRequest(handler, uri).Code != 206 {
		t.Fatal("initial read failed")
	}
	lease.mu.Lock()
	previous := lease.links["fixture-player"]
	previous.expires = time.Now().Add(-time.Second)
	lease.links["fixture-player"] = previous
	lease.mu.Unlock()
	w := playbackRecoveryRequest(handler, uri)
	if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), payload[42:104]) || d.links.Load() != 2 {
		t.Fatal("idle refresh lost range", w.Code, d.links.Load())
	}
}

func TestPlaybackLateFailureCannotInvalidateNewLinkOrAnotherUserAgent(t *testing.T) {
	lease := &cloudPlaybackLease{cloudPlaybackLinks: &cloudPlaybackLinks{links: map[string]cloudPlaybackLink{
		"fixture-player": {url: "https://example.invalid/new"},
		"other-player":   {url: "https://example.invalid/old"},
	}}}
	header := http.Header{"User-Agent": []string{"fixture-player"}}
	lease.invalidate(header, "https://example.invalid/old")
	if len(lease.links) != 2 {
		t.Fatal("old failure invalidated newer link")
	}
	lease.invalidate(header, "https://example.invalid/new")
	if len(lease.links) != 1 || lease.links["other-player"].url == "" {
		t.Fatal("unrelated user agent link invalidated")
	}
}

func TestIndependentPlaybackAndReferenceLeasesShareOneDownloadTicket(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
	d := &playbackProxyFixture{rotating: true}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Model a provider where issuing a new ticket invalidates the previous
		// ticket for the same client. Readers must not repeatedly evict each other.
		if r.URL.Query().Get("ticket") != strconv.Itoa(int(d.links.Load())) {
			w.WriteHeader(403)
			return
		}
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	d.origin = upstream.URL
	file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	handler, firstURI, first := playbackRecoveryHandler(t, d, file)
	// A second metadata-verified object gets its own capability and lifetime.
	secondURL, err := playbackLeaseURL(d, d.MountPath, "/film.mp4", &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)})
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(secondURL)
	if u.RequestURI() == firstURI {
		t.Fatal("independent source reused its capability")
	}
	var workers sync.WaitGroup
	for _, uri := range []string{firstURI, u.RequestURI(), firstURI, u.RequestURI()} {
		workers.Add(1)
		go func(uri string) {
			defer workers.Done()
			w := playbackRecoveryRequest(handler, uri)
			if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), payload[42:104]) {
				t.Errorf("concurrent reader lost its ticket: %d", w.Code)
			}
		}(uri)
	}
	workers.Wait()
	if d.links.Load() != 1 {
		t.Fatal("independent readers reissued the same ticket", d.links.Load())
	}
	// Simulate invalidation outside these readers. A single refresh must repair
	// both capabilities, without leaving the other one stuck on an old URL.
	d.links.Add(1)
	if w := playbackRecoveryRequest(handler, firstURI); w.Code != 403 {
		t.Fatal("expiry not propagated", w.Code)
	}
	for _, uri := range []string{u.RequestURI(), firstURI} {
		w := playbackRecoveryRequest(handler, uri)
		if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), payload[42:104]) {
			t.Fatal("shared refresh failed", w.Code)
		}
	}
	if d.links.Load() != 3 {
		t.Fatal("refresh storm", d.links.Load())
	}
	// A different account/driver must obtain its own ticket even for identical
	// metadata, so its credentials and capability never inherit this cache.
	other := &playbackProxyFixture{origin: upstream.URL}
	_, _, separate := playbackRecoveryHandler(t, other, file)
	if separate.cloudPlaybackLinks == first.cloudPlaybackLinks {
		t.Fatal("download tickets crossed account identity")
	}
}

func TestCdnConnectionLimitDoesNotInvalidateTheVerifiedDownloadTicket(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"status":403,"message":"115 pmt 3-2"}`))
	}))
	defer upstream.Close()
	d := &playbackProxyFixture{origin: upstream.URL}
	file := &model.Object{ID: "9", Name: "film.mp4", Size: 1000, Modified: time.Unix(0, 0)}
	handler, uri, lease := playbackRecoveryHandler(t, d, file)
	for i := 0; i < 2; i++ {
		w := playbackRecoveryRequest(handler, uri)
		if w.Code != 403 || w.Header().Get("X-Thru3D-Upstream-Reason") != "cdn_connections_limited" || w.Body.Len() != 0 {
			t.Fatal("busy denial misclassified", w.Code)
		}
	}
	if d.links.Load() != 1 || len(lease.links) != 1 {
		t.Fatal("connection quota triggered a credential/ticket refresh")
	}
}

func TestArchivePlaybackUsesOneTicketPastTheVideoRefreshPeriod(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Thru3D-Archive-Read") != "" {
			t.Error("internal archive policy reached CDN")
		}
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	expiration := 2 * time.Hour
	d := &playbackProxyFixture{origin: upstream.URL, expiration: &expiration}
	file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	handler, uri, lease := playbackRecoveryHandler(t, d, file)
	read := func() {
		r := httptest.NewRequest("GET", uri, nil)
		r.Header.Set("User-Agent", "fixture-player")
		r.Header.Set("X-Thru3D-Archive-Read", "1")
		r.Header.Set("Range", "bytes=42-103")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), payload[42:104]) {
			t.Fatalf("archive read failed %d", w.Code)
		}
	}
	read()
	lease.mu.Lock()
	previous := lease.links["fixture-player"]
	if time.Until(previous.archiveExpires) < time.Hour {
		t.Fatal("provider expiry was replaced by the short video TTL")
	}
	previous.expires = time.Now().Add(-time.Minute)
	lease.links["fixture-player"] = previous
	lease.mu.Unlock()
	for i := 0; i < 24; i++ {
		read()
	}
	if d.links.Load() != 1 {
		t.Fatal("archive page/idle refresh reissued a valid download ticket", d.links.Load())
	}
	lease.mu.Lock()
	previous = lease.links["fixture-player"]
	previous.archiveExpires = time.Now().Add(-time.Second)
	lease.links["fixture-player"] = previous
	lease.mu.Unlock()
	read()
	read()
	if d.links.Load() != 2 {
		t.Fatal("real expiry did not refresh exactly once", d.links.Load())
	}
	t.Logf("archive_ranges=27 ticket_requests=%d (one initial + one actual expiry)", d.links.Load())
}

func TestCdnRateLimitDoesNotDiscardAnArchiveDownloadTicket(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		w.Write([]byte(`{"message":"too many requests"}`))
	}))
	defer upstream.Close()
	d := &playbackProxyFixture{origin: upstream.URL}
	file := &model.Object{ID: "9", Name: "film.mp4", Size: 1000, Modified: time.Unix(0, 0)}
	handler, uri, lease := playbackRecoveryHandler(t, d, file)
	for i := 0; i < 2; i++ {
		r := httptest.NewRequest("GET", uri, nil)
		r.Header.Set("User-Agent", "fixture-player")
		r.Header.Set("X-Thru3D-Archive-Read", "1")
		r.Header.Set("Range", "bytes=0-0")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 403 || w.Header().Get("X-Thru3D-Upstream-Reason") != "cdn_rate_limited" {
			t.Fatal(w.Code, w.Header())
		}
	}
	if d.links.Load() != 1 || len(lease.links) != 1 {
		t.Fatal("rate limit caused a new provider ticket", d.links.Load())
	}
}

func TestPlaybackFailureNamesTheStepAndErrorKind(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 32)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/broken" {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer upstream.Close()
	file := &model.Object{ID: "9", Name: "film.mp4", Size: int64(len(payload)), Modified: time.Unix(0, 0)}
	for _, test := range []struct {
		name, origin string
		partSize     int
		userAgent    string
		step, kind   string
	}{
		{"whole read", "/broken", 0, "fixture-player", "proxy", "http"},
		{"first part", "/broken", 16, "fixture-player", "first_part", ""},
		{"provider link", "/valid", 0, "other-player", "link", "other"},
	} {
		t.Run(test.name, func(t *testing.T) {
			d := &playbackProxyFixture{origin: upstream.URL + test.origin, partSize: test.partSize}
			handler, uri, _ := playbackRecoveryHandler(t, d, file)
			r := httptest.NewRequest("GET", uri, nil)
			r.Header.Set("User-Agent", test.userAgent)
			r.Header.Set("Range", "bytes=42-103")
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code < 400 || w.Header().Get("X-Thru3D-Read-Step") != test.step {
				t.Fatal("failure step", w.Code, w.Header().Get("X-Thru3D-Read-Step"))
			}
			if test.kind != "" && w.Header().Get("X-Thru3D-Read-Error") != test.kind {
				t.Fatal("error kind", w.Header().Get("X-Thru3D-Read-Error"))
			}
		})
	}
	d := &playbackProxyFixture{origin: upstream.URL + "/valid"}
	handler, uri, _ := playbackRecoveryHandler(t, d, file)
	if w := playbackRecoveryRequest(handler, uri); w.Code != 206 || w.Header().Get("X-Thru3D-Read-Step") != "" {
		t.Fatal("a successful read must not carry a failure label", w.Code)
	}
}

func TestReadErrorClassKeepsOnlyTheKind(t *testing.T) {
	dial := func(inner error) error {
		return &url.Error{Op: "Get", URL: "https://cdn.example/secret", Err: &net.OpError{Op: "dial", Net: "tcp", Err: inner}}
	}
	for _, test := range []struct {
		err  error
		want string
	}{
		{nil, ""},
		{dial(&net.DNSError{Err: "no such host", Name: "cdn.example", IsNotFound: true}), "dns"},
		{dial(syscall.ECONNREFUSED), "connect"},
		{fmt.Errorf("get link: %w", context.DeadlineExceeded), "timeout"},
		{context.Canceled, "canceled"},
		{fmt.Errorf("http request failure,status: %w", cloudnet.HttpStatusCodeError(500)), "http"},
		{&url.Error{Op: "Get", URL: "https://cdn.example", Err: x509.UnknownAuthorityError{}}, "tls"},
		{&url.Error{Op: "Get", URL: "https://cdn.example", Err: io.ErrUnexpectedEOF}, "eof"},
		{&net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNRESET}, "network"},
		{pkgerrors.WithMessage(errs.ObjectNotFound, "failed to get file"), "not_found"},
		{errors.New("provider said no"), "other"},
	} {
		if got := readErrorClass(test.err); got != test.want {
			t.Errorf("%v: got %q, want %q", test.err, got, test.want)
		}
	}
}

func TestRecoveredStreamPanicIsLabelled(t *testing.T) {
	engine := gin.New()
	engine.Use(gin.CustomRecovery(recoverStream))
	engine.GET("/panic", func(*gin.Context) { panic("handler failed") })
	w := httptest.NewRecorder()
	engine.ServeHTTP(w, httptest.NewRequest("GET", "/panic", nil))
	if w.Code != 500 || w.Header().Get("X-Thru3D-Read-Step") != "panic" {
		t.Fatal("panic was not labelled", w.Code, w.Header())
	}
}
