package cloudcore

import (
	"bytes"
	"context"
	"errors"
	"io"
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

type playbackProxyFixture struct {
	deletionFixture
	origin string
	links  atomic.Int32
}

func (d *playbackProxyFixture) Get(context.Context, string) (model.Obj, error) {
	panic("proxy re-entered generic Getter / 8000-row full-directory fallback")
}
func (d *playbackProxyFixture) List(context.Context, model.Obj, model.ListArgs) ([]model.Obj, error) {
	panic("proxy enumerated a directory")
}
func (d *playbackProxyFixture) Link(_ context.Context, obj model.Obj, args model.LinkArgs) (*model.Link, error) {
	if obj.GetID() != "9" || obj.ModTime().Unix() != 0 || args.Header.Get("User-Agent") != "fixture-player" {
		return nil, errors.New("wrong identity or user agent")
	}
	d.links.Add(1)
	return &model.Link{URL: d.origin, Header: http.Header{"User-Agent": []string{"provider-agent"}}}, nil
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
