package _115_open

import (
	"context"
	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"io"
	"net/http"
	"strings"
	"testing"
)

type playerSearchTransport func(*http.Request) (*http.Response, error)

func (f playerSearchTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestPlayerSearch115UsesNativePageAndLazyParent(t *testing.T) {
	requests := 0
	transport := playerSearchTransport(func(r *http.Request) (*http.Response, error) {
		requests++
		body := ""
		switch r.URL.Path {
		case "/open/ufile/search":
			q := r.URL.Query()
			if q.Get("search_value") != "旅行" || q.Get("cid") != "0" || q.Get("type") != "4" || q.Get("limit") != "48" || q.Get("offset") != "0" {
				t.Fatal("wrong search parameters", q)
			}
			body = `{"state":true,"count":49,"offset":0,"data":[{"file_id":"1","file_name":"旅行.mp4","file_size":"128","file_category":"1","parent_id":"9"}]}`
		case "/open/folder/get_info":
			body = `{"state":true,"data":{"file_id":"9","file_name":"旅行","paths":[{"file_id":"0","file_name":""}]}}`
		default:
			t.Fatal("unexpected provider endpoint", r.URL.Path)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	})
	d := &Open115{}
	d.RootFolderID = "0"
	d.client = sdk.New(sdk.WithAccessToken("fixture")).SetHttpClient(&http.Client{Transport: transport})
	files, next, total, limited, err := d.PlayerSearch(context.Background(), &model.Object{ID: "0", IsFolder: true}, "旅行", "video", "")
	if err != nil || len(files) != 1 || next != "1" || total != 49 || limited || requests != 1 {
		t.Fatal("native search page failed", err, next, total, requests)
	}
	if files[0].GetPath() != "" {
		t.Fatal("search eagerly fabricated path")
	}
	parent, err := d.PlayerSearchParent(context.Background(), "9")
	if err != nil || parent != "/旅行" || requests != 2 {
		t.Fatal("lazy parent failed", parent, err)
	}
	if _, _, _, _, err = d.PlayerSearch(context.Background(), &model.Object{ID: "0"}, "旅行", "video", "10000"); err == nil {
		t.Fatal("search exceeded provider result limit")
	}
}
