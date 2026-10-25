package aliyundrive_open

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

func TestPdfColdRecoveryUsesExactIDOrLegacyPathWithoutList(t *testing.T) {
	old := base.RestyClient
	base.RestyClient = resty.New()
	defer func() { base.RestyClient = old }()
	d := &AliyundriveOpen{}
	d.RootFolderID = "root"
	d.DriveId = "drive"
	d.AccessToken = "fixture"
	d.limiter = getLimiterForUser("pdf-cold")
	defer d.limiter.free()
	calls := 0
	expected := "get"
	replyID := "pdf-id"
	base.RestyClient.SetTransport(playerListingTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		if r.URL.Path != "/adrive/v1.0/openFile/"+expected || body["drive_id"] != "drive" {
			t.Fatal("unexpected scan", r.URL.Path)
		}
		if expected == "get" && body["file_id"] != "pdf-id" || expected == "get_by_path" && body["file_path"] != "/Comics/漫画 #?%.PDF" {
			t.Fatal(body)
		}
		reply, _ := json.Marshal(map[string]any{"file_id": replyID, "name": "漫画 #?%.PDF", "size": 3145925, "type": "file"})
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(string(reply))), Request: r}, nil
	}))
	for _, id := range []string{"pdf-id", ""} {
		if id == "" {
			expected = "get_by_path"
		}
		obj, link, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", id)
		if err != nil || obj.GetID() != "pdf-id" || obj.GetSize() != 3145925 || link != nil {
			t.Fatal(err)
		}
	}
	if calls != 2 {
		t.Fatal(calls)
	}
	expected = "get"
	replyID = "replaced"
	if _, _, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", "pdf-id"); err == nil {
		t.Fatal("replacement accepted")
	}
	d.RootFolderID = "custom-root"
	if _, _, err := d.PlayerArchiveTarget(context.Background(), "/Comics/book.pdf", ""); err == nil || calls != 3 {
		t.Fatal("custom root scan")
	}
}
