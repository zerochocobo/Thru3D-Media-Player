package baidu_netdisk

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/go-resty/resty/v2"
)

func TestPlayerBaiduDirectoryUsesOneNativeBatchAndServerSort(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &BaiduNetdisk{}
	d.RootFolderPath = "/Library"
	d.OrderBy = "name"
	d.OrderDirection = "asc"
	orders := map[string]string{"source": "name", "name_asc": "name", "name_desc": "name", "size_asc": "size", "size_desc": "size", "modified_asc": "time", "modified_desc": "time"}
	for order, field := range orders {
		calls := 0
		base.RestyClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			q := r.URL.Query()
			if q.Get("dir") != "/Library/Movies" || q.Get("limit") != "48" || q.Get("start") != "96" || q.Get("order") != field || q.Get("method") != "list" {
				t.Fatal(q)
			}
			if strings.HasSuffix(order, "desc") != (q.Get("desc") == "1") {
				t.Fatal(q)
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"errno":0,"list":[{"fs_id":9007199254740993,"path":"/Library/Movies/movie.mp4","server_filename":"movie.mp4","size":90000000000}]}`)), Request: r}, nil
		}))
		dir, err := d.PlayerFolder(context.Background(), "/Movies", "folder-id")
		if err != nil {
			t.Fatal(err)
		}
		items, next, total, err := d.PlayerPage(context.Background(), dir, "96", order)
		if err != nil || calls != 1 || len(items) != 1 || next != "" || total != 97 || items[0].GetID() != "9007199254740993" {
			t.Fatal(order, err, calls, next, total)
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, _, _, err = d.PlayerPage(ctx, dir, "96", order); err == nil || calls != 1 {
			t.Fatal("cancelled request succeeded")
		}
	}
}
