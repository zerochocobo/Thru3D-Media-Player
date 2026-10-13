package onedrive

import (
	"context"
	"fmt"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"io"
	"net/http"
	"strings"
	"testing"
)

type playerSearchTransport func(*http.Request) (*http.Response, error)

func (f playerSearchTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestPlayerSearchOneDriveScopePathsAndCursorOrigin(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	calls := 0
	base.RestyClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != "graph.microsoft.com" || r.Header.Get("Authorization") != "Bearer fixture" || !strings.Contains(r.URL.Path, "/drive/root:/Library:/search") || r.URL.Query().Get("$top") != "48" {
			return nil, fmt.Errorf("wrong OneDrive request")
		}
		body := `{"value":[{"id":"1","name":"旅行 #%.mp4","size":128,"file":{},"parentReference":{"path":"/drive/root:/Library/旅行%20folder"},"lastModifiedDateTime":"2026-10-12T00:00:00Z"}]}`
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	}))
	d := &Onedrive{}
	d.Region = "global"
	d.RootFolderPath = "/Library"
	d.AccessToken = "fixture"
	files, next, _, _, err := d.PlayerSearch(context.Background(), &model.Object{Path: "/Library", IsFolder: true}, "旅行", "video", "")
	if err != nil || len(files) != 1 || files[0].GetPath() != "/旅行 folder/旅行 #%.mp4" || next != "" {
		t.Fatal("search path mapping failed", err, files)
	}
	_, _, _, _, err = d.PlayerSearch(context.Background(), &model.Object{Path: "/Library"}, "旅行", "video", "https://attacker.invalid/v1.0/me/drive/root/search")
	if err == nil || calls != 1 {
		t.Fatal("forwarded credentials to foreign cursor")
	}
}
