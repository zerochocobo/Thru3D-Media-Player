package quark_open

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/go-resty/resty/v2"
)

type playerListingTransport func(*http.Request) (*http.Response, error)

func (f playerListingTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestPlayerQuarkDirectoryUsesOnlyRequestedCursorAndVerifiedSorts(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &QuarkOpen{conf: Conf{api: "https://open-api-drive.quark.cn", ua: "fixture"}}
	d.RootFolderID = "0"
	d.OrderBy = "file_name"
	d.OrderDirection = "asc"
	d.AccessToken = "fixture"
	d.AppID = "fixture"
	d.SignKey = "fixture"
	for order, field := range map[string]string{"source": "file_name", "name_asc": "file_name", "name_desc": "file_name", "modified_asc": "updated_at", "modified_desc": "updated_at"} {
		calls := 0
		base.RestyClient.SetTransport(playerListingTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			direction := "asc"
			if strings.HasSuffix(order, "desc") {
				direction = "desc"
			}
			if r.URL.Path != "/open/v1/file/list" || body["parent_fid"] != "folder" || body["size"] != float64(48) || body["sort"] != field+":"+direction {
				t.Fatal(r.URL, body)
			}
			response := `{"status":200,"data":{"file_list":[],"last_page":false,"next_query_cursor":{"version":"1","token":"opaque-next"}}}`
			if calls == 2 {
				if body["query_cursor"].(map[string]any)["token"] != "opaque-next" {
					t.Fatal(body)
				}
				response = `{"status":200,"data":{"file_list":[{"fid":"2","filename":"two.mp4","size":90000000000,"file_type":"1"}],"last_page":true}}`
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(response)), Request: r}, nil
		}))
		dir, err := d.PlayerFolder(context.Background(), "/Movies", "folder")
		if err != nil {
			t.Fatal(err)
		}
		items, next, total, err := d.PlayerPage(context.Background(), dir, "", order)
		if err != nil || calls != 1 || len(items) != 0 || next == "" || total != -1 {
			t.Fatal(err, calls, next, total)
		}
		items, next, _, err = d.PlayerPage(context.Background(), dir, next, order)
		if err != nil || calls != 2 || len(items) != 1 || next != "" {
			t.Fatal(err, calls, next)
		}
		if _, _, _, err = d.PlayerPage(context.Background(), dir, "", "size_desc"); err == nil || calls != 2 {
			t.Fatal("unsupported size sort read metadata")
		}
	}
	if _, err := d.PlayerFolder(context.Background(), "/unknown", ""); err == nil {
		t.Fatal("missing folder identity caused fallback enumeration")
	}
}
