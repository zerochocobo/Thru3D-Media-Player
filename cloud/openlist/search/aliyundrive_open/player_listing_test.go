package aliyundrive_open

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
func TestPlayerAliyunDirectoryUsesOpaqueMarkerAndServerSort(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &AliyundriveOpen{}
	d.RootFolderID = "root"
	d.DriveId = "drive"
	d.AccessToken = "fixture"
	d.OrderBy = "name"
	d.OrderDirection = "ASC"
	d.limiter = getLimiterForUser("paging-fixture")
	defer d.limiter.free()
	orders := map[string]string{"source": "name", "name_asc": "name", "name_desc": "name", "size_asc": "size", "size_desc": "size", "modified_asc": "updated_at", "modified_desc": "updated_at"}
	for order, field := range orders {
		calls := 0
		base.RestyClient.SetTransport(playerListingTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			if r.URL.Path != "/adrive/v1.0/openFile/list" || body["limit"] != float64(48) || body["parent_file_id"] != "folder" || body["order_by"] != field || body["drive_id"] != "drive" {
				t.Fatal(r.URL, body)
			}
			if strings.HasSuffix(order, "desc") != (body["order_direction"] == "DESC") {
				t.Fatal(body)
			}
			response := `{"items":[{"file_id":"1","name":"one.mp4","type":"file","size":90000000000}],"next_marker":"opaque:next"}`
			if calls == 2 {
				if body["marker"] != "opaque:next" {
					t.Fatal(body)
				}
				response = `{"items":[{"file_id":"2","name":"two.mp4","type":"file"}]}`
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(response)), Request: r}, nil
		}))
		dir, err := d.PlayerFolder(context.Background(), "/Movies", "folder")
		if err != nil {
			t.Fatal(err)
		}
		items, next, total, err := d.PlayerPage(context.Background(), dir, "", order)
		if err != nil || calls != 1 || len(items) != 1 || next != "opaque:next" || total != -1 {
			t.Fatal(err, calls, next, total)
		}
		_, next, _, err = d.PlayerPage(context.Background(), dir, next, order)
		if err != nil || calls != 2 || next != "" {
			t.Fatal(err, calls, next)
		}
	}
}
