package onedrive

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/go-resty/resty/v2"
)

func TestPlayerOneDriveDirectoryFollowsOneTrustedNextLinkAtATime(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &Onedrive{}
	d.Region = "global"
	d.RootFolderPath = "/Library"
	d.AccessToken = "fixture"
	for order, field := range map[string]string{"source": "", "name_asc": "name", "name_desc": "name", "size_asc": "size", "size_desc": "size", "modified_asc": "lastModifiedDateTime", "modified_desc": "lastModifiedDateTime"} {
		calls := 0
		base.RestyClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Header.Get("Authorization") != "Bearer fixture" || !strings.Contains(r.URL.Path, "/items/folder/children") {
				t.Fatal(r.URL)
			}
			q := r.URL.Query()
			if calls == 1 {
				expected := ""
				if field != "" {
					direction := "asc"
					if strings.HasSuffix(order, "desc") {
						direction = "desc"
					}
					expected = field + " " + direction
				}
				if q.Get("$top") != "48" || q.Get("$orderby") != expected {
					t.Fatal(q)
				}
			} else if q.Get("$skiptoken") != "opaque-next" {
				t.Fatal(q)
			}
			response := `{"value":[{"id":"one","name":"one.mp4","size":90000000000,"file":{},"lastModifiedDateTime":"2026-10-17T00:00:00Z"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/canonical-drive/items/folder/children?$skiptoken=opaque-next"}`
			if calls == 2 {
				response = `{"value":[{"id":"two","name":"two.mp4","file":{}}]}`
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(response)), Request: r}, nil
		}))
		dir, err := d.PlayerFolder(context.Background(), "/Movies", "folder")
		if err != nil {
			t.Fatal(err)
		}
		items, next, total, err := d.PlayerPage(context.Background(), dir, "", order)
		if err != nil || calls != 1 || len(items) != 1 || next == "" || total != -1 {
			t.Fatal(err, calls, next, total)
		}
		_, next, _, err = d.PlayerPage(context.Background(), dir, next, order)
		if err != nil || calls != 2 || next != "" {
			t.Fatal(err, calls, next)
		}
		for _, bad := range []string{"https://attacker.invalid/children", "http://graph.microsoft.com/v1.0/me/drive/root:/Library/Movies:/children", "https://graph.microsoft.com/v1.0/me/drive/root:/Other:/children", "https://user:pass@graph.microsoft.com/v1.0/me/drive/root:/Library/Movies:/children"} {
			if _, _, _, err = d.PlayerPage(context.Background(), dir, bad, order); err == nil || calls != 2 {
				t.Fatal("forwarded auth to invalid cursor", bad, calls)
			}
		}
	}
}
