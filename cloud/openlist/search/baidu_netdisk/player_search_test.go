package baidu_netdisk

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
func TestPlayerSearchBaiduUsesDirectoryRecursionAndCategory(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	calls := 0
	base.RestyClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		q := r.URL.Query()
		if r.URL.Host != "pan.baidu.com" || q.Get("method") != "search" || q.Get("key") != "旅行" || q.Get("dir") != "/Library" || q.Get("recursion") != "1" || q.Get("category") != "3" || q.Get("web") != "0" {
			return nil, fmt.Errorf("wrong Baidu search parameters")
		}
		body := `{"errno":0,"list":[{"fs_id":9007199254740993,"server_filename":"旅行.heic","path":"/Library/sub/旅行.heic","size":128,"isdir":0,"server_mtime":123}]}`
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	}))
	d := &BaiduNetdisk{}
	d.RootFolderPath = "/Library"
	d.AccessToken = "fixture"
	files, next, _, _, err := d.PlayerSearch(context.Background(), &model.Object{Path: "/Library", IsFolder: true}, "旅行", "image", "")
	if err != nil || len(files) != 1 || files[0].GetID() != "9007199254740993" || files[0].GetPath() != "/sub/旅行.heic" || next != "" {
		t.Fatal("native response mapping failed", err)
	}
	_, _, _, _, err = d.PlayerSearch(context.Background(), &model.Object{Path: "/Library"}, strings.Repeat("字", 31), "image", "")
	if err == nil || calls != 1 {
		t.Fatal("Baidu search ignored query limit")
	}
}
