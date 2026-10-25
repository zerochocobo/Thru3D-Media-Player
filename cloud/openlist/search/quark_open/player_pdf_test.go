package quark_open

import (
	"context"
	"encoding/json"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPdfLinkUsesOriginalFileIDAndPreservesDownloadCookie(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &QuarkOpen{conf: Conf{api: "https://open-api-drive.quark.cn", ua: "fixture"}}
	d.AccessToken = "fixture"
	d.AppID = "fixture"
	d.SignKey = "fixture"
	calls := 0
	base.RestyClient.SetTransport(playerListingTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		if r.Method != "POST" || r.URL.Path != "/open/v1/file/get_download_url" || body["fid"] != "pdf-id" {
			t.Fatal("PDF used an unexpected endpoint", r.URL.Path)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"status":200,"data":{"download_url":"https://fixture.invalid/original.pdf"}}`)), Request: r}, nil
	}))
	link, err := d.Link(context.Background(), &model.Object{ID: "pdf-id", Name: "漫画 #?%.PDF", Size: 3145925}, model.LinkArgs{})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 || link.URL != "https://fixture.invalid/original.pdf" || link.Header.Get("Cookie") == "" || link.RangeReader != nil {
		t.Fatal("PDF original download changed")
	}
}
