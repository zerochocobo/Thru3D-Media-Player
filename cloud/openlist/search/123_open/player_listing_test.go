package _123_open

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
)

func TestPlayer123CursorPages(t *testing.T) {
	originalClient := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = originalClient }()
	old := FileList
	defer func() { FileList = old }()
	mode := "normal"
	limit := "48"
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer fixture" || r.Header.Get("platform") != "open_platform" {
			t.Error("missing official headers")
		}
		if r.URL.Query().Get("limit") != limit || r.URL.Query().Get("parentFileId") != "0" {
			t.Error("wrong page request")
		}
		w.Header().Set("Content-Type", "application/json")
		switch mode {
		case "repeat":
			fmt.Fprint(w, `{"code":0,"data":{"lastFileId":2,"fileList":[]}}`)
		case "duplicate":
			fmt.Fprint(w, `{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":1},{"fileId":1}]}}`)
		default:
			if r.URL.Query().Get("lastFileId") == "0" {
				fmt.Fprint(w, `{"code":0,"data":{"lastFileId":2,"fileList":[{"fileId":1,"filename":"中文.mp4","size":100,"type":0},{"fileId":2,"filename":"deleted","trashed":1}]}}`)
			} else {
				fmt.Fprint(w, `{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":3,"filename":"folder","type":1}]}}`)
			}
		}
	}))
	defer server.Close()
	FileList = InitApiInfo(server.URL, 0)
	d := &Open123{Addition: Addition{AccessToken: "fixture"}, tm: &tokenManager{expiredAt: time.Now().Add(time.Hour)}}
	d.RootFolderID = "0"
	root, err := d.PlayerFolder(context.Background(), "/", "999")
	if err != nil || root.GetID() != "0" {
		t.Fatal("root must use configured ID", err)
	}
	rows, next, total, err := d.PlayerPage(context.Background(), root, "", "source")
	if err != nil || len(rows) != 1 || rows[0].GetName() != "中文.mp4" || next != "2" || total != -1 {
		t.Fatal(rows, next, total, err)
	}
	rows, next, _, err = d.PlayerPage(context.Background(), root, next, "source")
	if err != nil || len(rows) != 1 || !rows[0].IsDir() || next != "" {
		t.Fatal(rows, next, err)
	}
	limit = "100"
	restored, err := d.PlayerFolder(context.Background(), "/folder", "")
	if err != nil || restored.GetID() != "3" {
		t.Fatal("restored path resolution failed", err)
	}
	beforeHint := calls
	hinted, err := d.PlayerFolder(context.Background(), "/folder", "3")
	if err != nil || hinted.GetID() != "3" || calls != beforeHint {
		t.Fatal("folder hint replayed listing", err)
	}
	if _, err := d.PlayerFolder(context.Background(), "/missing", ""); err == nil {
		t.Error("missing folder accepted")
	}
	limit = "48"
	for _, value := range []string{"-1", "01", "0", "x"} {
		if _, _, _, err := d.PlayerPage(context.Background(), root, value, "source"); err == nil {
			t.Error("invalid cursor accepted", value)
		}
	}
	for _, size := range []int{0, 101} {
		if _, _, _, err := d.PlayerPageSized(context.Background(), root, "", "source", size); err == nil {
			t.Error("invalid size accepted")
		}
	}
	if _, _, _, err := d.PlayerPage(context.Background(), root, "", "name_asc"); err == nil {
		t.Error("unsupported sort accepted")
	}
	before := calls
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, _, err := d.PlayerPage(ctx, root, "", "source"); err == nil || calls != before {
		t.Error("cancellation ignored")
	}
	mode = "repeat"
	if _, _, _, err := d.PlayerPage(context.Background(), root, "2", "source"); err == nil {
		t.Error("repeated cursor accepted")
	}
	mode = "duplicate"
	if _, _, _, err := d.PlayerPage(context.Background(), root, "", "source"); err == nil {
		t.Error("duplicate ID accepted")
	}
	if _, err := d.PlayerFolder(context.Background(), "/../bad", "3"); err == nil {
		t.Error("invalid path accepted")
	}
	if _, _, _, err := d.PlayerPage(context.Background(), &model.Object{ID: "-1"}, "", "source"); err == nil {
		t.Error("invalid folder accepted")
	}
}

func TestPlayer123HungRequestDoesNotHoldTheNextAccountsQuota(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	entered := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer slow" {
			close(entered)
			select {
			case <-r.Context().Done():
				return
			case <-release:
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, "{\"code\":0}")
	}))
	defer server.Close()
	defer close(release)
	quota := InitApiInfo(server.URL, 1)
	driver := func(token string) *Open123 {
		d := &Open123{tm: &tokenManager{expiredAt: time.Now().Add(time.Hour)}}
		d.AccessToken = token
		return d
	}
	slow, fast := driver("slow"), driver("fast")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := slow.Request(quota, http.MethodGet, func(r *resty.Request) { r.SetContext(ctx) }, nil)
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("slow driver not dispatched")
	}
	healthy, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	if _, err := fast.Request(quota, http.MethodGet, func(r *resty.Request) { r.SetContext(healthy) }, nil); err != nil {
		t.Fatal("healthy account waited for slow response", err)
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected cancellation")
		}
	case <-time.After(time.Second):
		t.Fatal("slow request did not return")
	}
}
