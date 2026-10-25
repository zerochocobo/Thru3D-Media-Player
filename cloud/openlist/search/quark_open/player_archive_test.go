package quark_open

import (
	"context"
	"encoding/json"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/go-resty/resty/v2"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPdfColdRecoveryUsesOneDownloadRequestAndNeverLists(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &QuarkOpen{conf: Conf{api: "https://open-api-drive.quark.cn", ua: "fixture"}}
	d.AccessToken = "fixture"
	d.AppID = "fixture"
	d.SignKey = "fixture"
	calls := 0
	replyID := "pdf-id"
	base.RestyClient.SetTransport(playerListingTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		if r.URL.Path != "/open/v1/file/get_download_url" || body["fid"] != "pdf-id" {
			t.Fatal("unexpected directory scan", r.URL.Path)
		}
		bodyJSON, _ := json.Marshal(map[string]any{"status": 200, "data": map[string]any{"fid": replyID, "size": 3145925, "file_name": "漫画 #?%.PDF", "download_url": "https://fixture.invalid/book.pdf"}})
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(string(bodyJSON))), Request: r}, nil
	}))
	obj, link, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", "pdf-id")
	if err != nil || calls != 1 || obj.GetID() != "pdf-id" || obj.GetSize() != 3145925 || link.Header.Get("Cookie") == "" {
		t.Fatal(err, calls)
	}
	if _, _, err = d.PlayerArchiveTarget(context.Background(), "/Comics/book.pdf", ""); err == nil || calls != 1 {
		t.Fatal("legacy identity triggered scan")
	}
	replyID = "replaced"
	if _, _, err = d.PlayerArchiveTarget(context.Background(), "/Comics/book.pdf", "pdf-id"); err == nil {
		t.Fatal("replacement accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err = d.PlayerArchiveTarget(ctx, "/Comics/book.pdf", "pdf-id"); err == nil || calls != 2 {
		t.Fatal("cancelled IO")
	}
}
