package onedrive

import (
	"context"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPdfLinkPreservesConfiguredRootAndReadsOriginalDownloadURL(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &Onedrive{}
	d.Region = "global"
	d.RootFolderPath = "/Library"
	d.AccessToken = "fixture"
	calls := 0
	base.RestyClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Header.Get("Authorization") != "Bearer fixture" || !strings.Contains(r.URL.Path, "/Library/Comics/漫画 #?%.PDF") || r.URL.RawQuery != "" {
			t.Fatal("PDF path/authorization changed", r.URL.Path)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"id":"pdf-id","name":"漫画 #?%.PDF","file":{"mimeType":"application/pdf"},"@microsoft.graph.downloadUrl":"https://fixture.invalid/original.pdf"}`)), Request: r}, nil
	}))
	link, err := d.Link(context.Background(), &model.Object{ID: "pdf-id", Name: "漫画 #?%.PDF", Path: "/Library/Comics/漫画 #?%.PDF", Size: 3145925}, model.LinkArgs{})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 || link.URL != "https://fixture.invalid/original.pdf" || link.RangeReader != nil {
		t.Fatal("PDF original download changed")
	}
}
