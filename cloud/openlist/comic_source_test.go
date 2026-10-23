package cloudcore

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/conf"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/gin-gonic/gin"
)

type comicProxyFixture struct {
	playbackProxyFixture
	selected model.Obj
}

func (d *comicProxyFixture) Link(_ context.Context, file model.Obj, args model.LinkArgs) (*model.Link, error) {
	if file != d.selected || args.Header.Get("X-Thru3D-Archive-Read") != "" {
		return nil, errors.New("archive object or provider header changed")
	}
	d.links.Add(1)
	return &model.Link{URL: d.origin}, nil // Mirrors OneDrive/Quark/WebDAV's absent cache duration.
}

func TestComicGenericCloudRangesUseOneVerifiedObjectAndDownloadAddress(t *testing.T) {
	for _, id := range []string{"item-guid", ""} {
		t.Run("object_id_"+id, func(t *testing.T) {
			previousConfig, previousBase := conf.Conf, streamBase
			conf.Conf = conf.DefaultConfig(t.TempDir())
			streamBase = "http://127.0.0.1:1/generic"
			defer func() { conf.Conf = previousConfig; streamBase = previousBase }()
			payload := bytes.Repeat([]byte{42}, 1024)
			var downloads atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				downloads.Add(1)
				if r.Header.Get("X-Thru3D-Archive-Read") != "" {
					t.Error("internal header reached provider")
				}
				http.ServeContent(w, r, "book.zip", time.Unix(0, 0), bytes.NewReader(payload))
			}))
			defer upstream.Close()
			d := &comicProxyFixture{}
			d.origin = upstream.URL
			d.ProxyRange = true // Archive reads must preserve the provider's real 206 support.
			d.MountPath = "/12345678-1234-1234-1234-123456789abc"
			d.selected = &model.Object{ID: id, Name: "book.zip", Size: 1024, Path: "/Comics/book.zip"}
			gets := 0
			target := cloudTarget{Mount: d.MountPath, Path: "/Comics/book.zip", ID: id, Size: 1024}
			lookup := func(string) (driver.Driver, string, error) { return d, target.Path, nil }
			get := func(context.Context, driver.Driver, string) (model.Obj, error) { gets++; return d.selected, nil }
			location, e := comicCloudSource(context.Background(), target, lookup, get)
			if e != nil {
				t.Fatal(e)
			}
			u, _ := url.Parse(location)
			key := strings.Split(strings.TrimPrefix(u.Path, "/generic-archive/"), "/")[0]
			defer func() {
				cloudPlaybackLeases.Lock()
				delete(cloudPlaybackLeases.items, key)
				cloudPlaybackLeases.Unlock()
			}()
			engine := gin.New()
			engine.GET("/generic-archive/:lease/*name", func(c *gin.Context) { servePlayback115(c, lookup) })
			for i := 0; i < 32; i++ {
				r := httptest.NewRequest("GET", u.RequestURI(), nil)
				r.Header.Set("X-Thru3D-Archive-Read", "1")
				r.Header.Set("Range", "bytes=42-103")
				w := httptest.NewRecorder()
				engine.ServeHTTP(w, r)
				if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), payload[42:104]) {
					t.Fatal("generic comic range failed", w.Code)
				}
			}
			if gets != 1 || d.links.Load() != 1 || downloads.Load() != 32 {
				t.Fatal("generic ranges re-entered metadata/link lookup", gets, d.links.Load(), downloads.Load())
			}
			t.Logf("ranges=%d object_lookups=%d download_address_requests=%d", downloads.Load(), gets, d.links.Load())
			d.Disabled = true
			w := httptest.NewRecorder()
			engine.ServeHTTP(w, httptest.NewRequest("GET", u.RequestURI(), nil))
			if w.Code != http.StatusGone || downloads.Load() != 32 {
				t.Fatal("disabled account still served archive", w.Code)
			}
		})
	}
}

func TestComicGenericSourceRejectsChangedMetadataBeforeCreatingALease(t *testing.T) {
	d := &comicProxyFixture{}
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	d.selected = &model.Object{ID: "item-guid", Name: "book.zip", Size: 1024}
	for _, target := range []cloudTarget{
		{Mount: d.MountPath, Path: "/book.zip", Size: 2048},
		{Mount: d.MountPath, Path: "/book.zip", Size: 1024, ID: "replacement"},
		{Mount: d.MountPath, Path: "/../book.zip", Size: 1024},
		{Mount: d.MountPath, Path: "/", Size: 1024},
	} {
		_, e := comicCloudSource(context.Background(), target,
			func(string) (driver.Driver, string, error) { return d, target.Path, nil },
			func(context.Context, driver.Driver, string) (model.Obj, error) { return d.selected, nil })
		if e == nil {
			t.Fatal("invalid or replaced source accepted", target)
		}
	}
	if d.links.Load() != 0 {
		t.Fatal("invalid metadata requested a download address")
	}
}

func TestComicSourceUsesListedObjectWithoutGenericGetOrFolderScan(t *testing.T) {
	d := &deletionFixture{}
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	file := &model.Object{ID: "object-guid", Name: "book.zip", Size: 1024, Path: "/Comics/book.zip"}
	key := d.MountPath + "/Comics\x00source"
	old := cursorCloudSessions[key]
	cursorCloudSessions[key] = &cursorCloudSession{storage: d, pages: map[int]cursorCloudPage{4800: {objects: []model.Obj{file}}}}
	defer func() {
		if old == nil {
			delete(cursorCloudSessions, key)
		} else {
			cursorCloudSessions[key] = old
		}
	}()
	selected, e := comicSourceObject(context.Background(), d, cloudTarget{Mount: d.MountPath, Path: "/Comics/book.zip", ID: file.ID, Size: 1024})
	if e != nil || selected != file {
		t.Fatal("visible archive lost its object binding", selected, e)
	}
	_, e = comicSourceObject(context.Background(), d, cloudTarget{Mount: d.MountPath, Path: "/Comics/missing.zip", Size: 1024})
	if e == nil {
		t.Fatal("cache miss should request a folder refresh rather than scanning it")
	}
	if len(d.reads) != 0 {
		t.Fatal("archive cache miss scanned the parent folder", d.reads)
	}
}

type comicRootFixture struct{ deletionFixture }

func (d *comicRootFixture) GetRootPath() string { return "/Library" }
func TestComicSearchObjectRestoresTheConfiguredSourceRoot(t *testing.T) {
	d := &comicRootFixture{}
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	file := &model.Object{ID: "object-guid", Name: "book.zip", Size: 1024, Path: "/Comics/book.zip"}
	key := "comic-path-check"
	cloudSearchSessions[key] = &searchSession{Storage: d, Request: cloudSearchRequest{Mount: d.MountPath},
		Objects: map[string]model.Obj{"token": file}, Paths: map[string]string{"token": "/Comics/book.zip"}}
	defer delete(cloudSearchSessions, key)
	selected, e := comicSourceObject(context.Background(), d, cloudTarget{Mount: d.MountPath, Path: "/Comics/book.zip", Size: 1024, ID: file.ID})
	if e != nil || selected.GetPath() != "/Library/Comics/book.zip" || selected.GetID() != file.ID {
		t.Fatal("search result lost source root or identity", selected, e)
	}
}

func TestComicProxyDoesNotEmulateRangesByDownloadingTheWholeArchive(t *testing.T) {
	oldConfig, oldBase := conf.Conf, streamBase
	conf.Conf = conf.DefaultConfig(t.TempDir())
	streamBase = "http://127.0.0.1:1/no-range"
	defer func() { conf.Conf = oldConfig; streamBase = oldBase }()
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Length", "1024")
		w.Write(bytes.Repeat([]byte{42}, 1024))
	}))
	defer upstream.Close()
	d := &comicProxyFixture{}
	d.origin = upstream.URL
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	d.ProxyRange = true
	d.selected = &model.Object{ID: "object-guid", Name: "book.zip", Size: 1024}
	location, e := boundPlaybackLeaseURL(d, d.MountPath, "/book.zip", d.selected, true)
	if e != nil {
		t.Fatal(e)
	}
	u, _ := url.Parse(location)
	key := strings.Split(strings.TrimPrefix(u.Path, "/no-range-archive/"), "/")[0]
	defer func() {
		cloudPlaybackLeases.Lock()
		delete(cloudPlaybackLeases.items, key)
		cloudPlaybackLeases.Unlock()
	}()
	engine := gin.New()
	engine.GET("/no-range-archive/:lease/*name", func(c *gin.Context) {
		servePlayback115(c, func(string) (driver.Driver, string, error) { return d, "/book.zip", nil })
	})
	r := httptest.NewRequest("GET", u.RequestURI(), nil)
	r.Header.Set("X-Thru3D-Archive-Read", "1")
	r.Header.Set("Range", "bytes=0-0")
	w := httptest.NewRecorder()
	engine.ServeHTTP(w, r)
	if w.Code == 206 || requests.Load() != 1 {
		t.Fatal("archive proxy synthesized Range support or retried whole response", w.Code, requests.Load())
	}
}
