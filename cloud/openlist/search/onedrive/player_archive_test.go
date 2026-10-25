package onedrive

import (
	"context"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/go-resty/resty/v2"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPdfColdRecoveryUsesOneGraphMetadataCallWithoutChildren(t *testing.T) {
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
		if !strings.HasSuffix(r.URL.Path, "/root:/Library/Comics/漫画 #?%.PDF:") || r.URL.RawQuery != "" {
			t.Fatal("not exact metadata", r.URL.Path)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"id":"pdf-id","name":"漫画 #?%.PDF","size":3145925,"lastModifiedDateTime":"2026-10-24T00:00:00Z","file":{"mimeType":"application/pdf"},"@microsoft.graph.downloadUrl":"https://fixture.invalid/original.pdf"}`)), Request: r}, nil
	}))
	for _, id := range []string{"pdf-id", ""} {
		obj, link, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", id)
		if err != nil || obj.GetID() != "pdf-id" || obj.ModTime().IsZero() || link.URL != "https://fixture.invalid/original.pdf" {
			t.Fatal(err)
		}
	}
	if calls != 2 {
		t.Fatal(calls)
	}
	if _, _, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", "other"); err == nil {
		t.Fatal("replacement accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := d.PlayerArchiveTarget(ctx, "/Comics/漫画 #?%.PDF", "pdf-id"); err == nil || calls != 3 {
		t.Fatal("cancelled IO")
	}
}
