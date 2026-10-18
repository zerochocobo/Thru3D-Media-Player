package cloudcore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"golang.org/x/net/webdav"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestCloudRequestCancellationBeforeDispatch(t *testing.T) {
	key, err := NewRequest()
	if err != nil {
		t.Fatal(err)
	}
	CancelRequest(key)
	if _, err = RequestCancelable("POST", "/search", "{}", key); err == nil {
		t.Fatal("cancelled request was dispatched")
	}
	CancelRequest(key)
	cloudRequestContexts.Lock()
	count := len(cloudRequestContexts.items)
	cloudRequestContexts.Unlock()
	if count != 0 {
		t.Fatal("cancelled request retained context")
	}
}
func TestCloudRequestCancellationWhileWaitingForOtherOperation(t *testing.T) {
	requestMu <- struct{}{}
	defer func() { <-requestMu }()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := requestContext(ctx, "POST", "/search", "{}"); done <- err }()
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled queued request succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation waited for a different JNI operation")
	}
}

type searchFixture struct {
	model.Storage
	addition     struct{}
	calls        int
	currentCalls int
}

func (d *searchFixture) Config() driver.Config          { return driver.Config{Name: "Player search fixture"} }
func (d *searchFixture) GetAddition() driver.Additional { return &d.addition }
func (d *searchFixture) Init(context.Context) error     { return nil }
func (d *searchFixture) Drop(context.Context) error     { return nil }
func (d *searchFixture) GetRoot(context.Context) (model.Obj, error) {
	return &model.Object{ID: "0", Path: "/", Name: "root", IsFolder: true}, nil
}
func (d *searchFixture) List(context.Context, model.Obj, model.ListArgs) ([]model.Obj, error) {
	return nil, nil
}
func (d *searchFixture) Link(context.Context, model.Obj, model.LinkArgs) (*model.Link, error) {
	panic("search downloaded media")
}
func (d *searchFixture) PlayerSearch(ctx context.Context, dir model.Obj, query, kind, cursor string) ([]model.Obj, string, int64, bool, error) {
	d.calls++
	if query == "paged" {
		offset, _ := strconv.Atoi(cursor)
		items := make([]model.Obj, 48)
		for i := range items {
			name := fmt.Sprintf("paged %03d.mp4", offset+i)
			items[i] = &model.Object{ID: fmt.Sprint(offset + i + 1), Path: "/folder/" + name, Name: name, Size: 128}
		}
		return items, strconv.Itoa(offset + 48), 1000, false, nil
	}
	if query == "miss" && cursor == "" {
		return []model.Obj{&model.Object{ID: "unsupported", Path: "/paper.txt", Name: "paper.txt"}}, "next", -1, false, nil
	}
	if cursor == "next" {
		return []model.Obj{&model.Object{ID: "found", Path: "/folder/miss.mp4", Name: "miss.mp4", Size: 128}}, "", -1, false, nil
	}
	items := make([]model.Obj, 0, 500)
	for i := 0; i < 500; i++ {
		name := fmt.Sprintf("movie %03d.mp4", i)
		items = append(items, &model.Object{ID: fmt.Sprint(i + 1), Path: "/folder/" + name, Name: name, Size: 128})
	}
	return items, "", 500, true, nil
}

func (d *searchFixture) PlayerSearchCurrent(ctx context.Context, dir model.Obj, query string) ([]model.Obj, bool, error) {
	d.currentCalls++
	items := make([]model.Obj, 200)
	for i := range items {
		items[i] = &model.Object{ID: fmt.Sprint(i + 1), Name: fmt.Sprintf("%s %03d.mp4", query, i), Size: 128}
	}
	return items, true, nil
}

// Runs while the parent integration test owns the core database and routes.
func assertCloudSearchCore(t *testing.T, call func(string, string, any) map[string]any) {
	t.Helper()
	directory := t.TempDir()
	if err := os.Mkdir(filepath.Join(directory, "nested"), 0700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 60; i++ {
		name := fmt.Sprintf("旅行 %03d.mp4", i)
		if err := os.WriteFile(filepath.Join(directory, name), []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	os.WriteFile(filepath.Join(directory, "nested", "旅行 hidden.mp4"), []byte("fixture"), 0600)
	var metadata, media atomic.Int32
	dav := &webdav.Handler{FileSystem: webdav.Dir(directory), LockSystem: webdav.NewMemLS()}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PROPFIND" {
			metadata.Add(1)
		}
		if r.Method == "GET" {
			media.Add(1)
		}
		dav.ServeHTTP(w, r)
	}))
	defer server.Close()
	mount := "/11111111-1111-4111-8111-111111111111"
	addition, _ := json.Marshal(map[string]any{"address": server.URL, "root_folder_path": "/", "vendor": "other"})
	created := call("POST", "/create", map[string]any{"mount_path": mount, "driver": "WebDav", "addition": string(addition), "cache_expiration": 5})
	id := int(created["data"].(map[string]any)["id"].(float64))
	defer Request("POST", fmt.Sprintf("/delete?id=%d", id), "")
	req := map[string]any{"mount": mount, "path": "/", "query": "旅行", "scope": "current", "kind": "video", "cursor": ""}
	first := call("POST", "/search", req)["data"].(map[string]any)
	if len(first["content"].([]any)) != 48 || first["total"] != float64(60) {
		t.Fatal("current search did not cover full directory", first)
	}
	reads := metadata.Load()
	req["cursor"] = first["next_cursor"]
	second := call("POST", "/search", req)["data"].(map[string]any)
	if len(second["content"].([]any)) != 12 || second["next_cursor"] != "" || metadata.Load() != reads || media.Load() != 0 {
		t.Fatal("paging searched subdirectories or downloaded media")
	}
	token := second["content"].([]any)[0].(map[string]any)["token"]
	resolved := call("POST", "/searchresolve", map[string]any{"mount": mount, "token": token})["data"].(map[string]any)
	if !strings.HasSuffix(resolved["path"].(string), ".mp4") {
		t.Fatal("result could not be resolved")
	}
	req["cursor"] = ""
	req["refresh"] = true
	os.WriteFile(filepath.Join(directory, "旅行 uploaded.mp4"), []byte("fixture"), 0600)
	refreshed := call("POST", "/search", req)["data"].(map[string]any)
	if refreshed["total"] != float64(61) || metadata.Load() <= reads {
		t.Fatal("refresh reused stale directory")
	}
	req["query"] = "different"
	req["cursor"] = first["next_cursor"]
	req["refresh"] = false
	body, _ := json.Marshal(req)
	raw, _ := Request("POST", "/search", string(body))
	var failed map[string]any
	json.Unmarshal([]byte(raw), &failed)
	if failed["code"] == float64(200) {
		t.Fatal("cursor reused for a different query")
	}
	req["scope"] = "all"
	req["cursor"] = ""
	raw, _ = Request("POST", "/search", mustSearchJSON(req))
	json.Unmarshal([]byte(raw), &failed)
	if failed["code"] == float64(200) {
		t.Fatal("WebDAV silently crawled full mount")
	}

	var native *searchFixture
	op.RegisterDriver(func() driver.Driver { native = &searchFixture{}; return native })
	mount = "/22222222-2222-4222-8222-222222222222"
	created = call("POST", "/create", map[string]any{"mount_path": mount, "driver": "Player search fixture", "addition": "{}", "cache_expiration": 5})
	id = int(created["data"].(map[string]any)["id"].(float64))
	defer Request("POST", fmt.Sprintf("/delete?id=%d", id), "")
	req = map[string]any{"mount": mount, "path": "/", "query": "movie", "scope": "all", "kind": "video", "cursor": ""}
	page := call("POST", "/search", req)["data"].(map[string]any)
	total := 0
	for {
		total += len(page["content"].([]any))
		if page["next_cursor"] == "" {
			break
		}
		req["cursor"] = page["next_cursor"]
		page = call("POST", "/search", req)["data"].(map[string]any)
	}
	if total != 200 || native.calls != 1 || page["limited"] != true {
		t.Fatal("bounded native response pagination failed", total, native.calls)
	}
	for _, scope := range []string{"current", "all"} {
		native.calls, native.currentCalls = 0, 0
		req["query"], req["scope"], req["cursor"] = "paged", scope, ""
		page = call("POST", "/search", req)["data"].(map[string]any)
		total, pages := 0, 0
		for {
			total += len(page["content"].([]any))
			pages++
			if page["next_cursor"] == "" {
				break
			}
			req["cursor"] = page["next_cursor"]
			page = call("POST", "/search", req)["data"].(map[string]any)
		}
		if total != 200 || pages != 5 || len(page["content"].([]any)) != 8 || page["limited"] != true ||
			scope == "all" && (native.calls != 5 || native.currentCalls != 0) ||
			scope == "current" && (native.calls != 0 || native.currentCalls != 1) {
			t.Fatal("user search did not stop at 200 with a final 8-row page", scope, total, pages, native.calls, native.currentCalls)
		}
	}
	req["scope"] = "all"
	req["query"] = "miss"
	req["cursor"] = ""
	page = call("POST", "/search", req)["data"].(map[string]any)
	if len(page["content"].([]any)) != 0 || page["next_cursor"] == "" {
		t.Fatal("filtered empty page ended search")
	}
	req["cursor"] = page["next_cursor"]
	page = call("POST", "/search", req)["data"].(map[string]any)
	if len(page["content"].([]any)) != 1 {
		t.Fatal("next native page lost supported result")
	}
}
func mustSearchJSON(value any) string { b, _ := json.Marshal(value); return string(b) }
