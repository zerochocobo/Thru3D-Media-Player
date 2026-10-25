package baidu_netdisk

import (
	"context"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/go-resty/resty/v2"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPdfColdRecoveryKeepsLargeIDAndReusesMetadataDownloadTicket(t *testing.T) {
	old, oldHead := base.RestyClient, base.NoRedirectClient
	base.RestyClient = resty.New()
	base.NoRedirectClient = resty.New()
	defer func() { base.RestyClient = old; base.NoRedirectClient = oldHead }()
	d := &BaiduNetdisk{}
	d.RootFolderPath = "/Library"
	d.AccessToken = "fixture"
	metas, searches, heads := 0, 0, 0
	changed := false
	base.RestyClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		reply := ""
		switch q.Get("method") {
		case "filemetas":
			metas++
			if q.Get("fsids") != "[9007199254740994]" || q.Get("dlink") != "1" {
				t.Fatal(q)
			}
			reply = `{"errno":0,"list":[{"fs_id":9007199254740994,"path":"/Library/Comics/漫画 #?%.PDF","size":3145925,"server_mtime":1792800000,"dlink":"https://fixture.invalid/ticket?x=1"}]}`
			if changed {
				reply = strings.ReplaceAll(reply, "/Library/Comics/", "/Another/")
			}
		case "search":
			searches++
			if q.Get("dir") != "/Library/Comics" || q.Get("num") != "500" {
				t.Fatal(q)
			}
			reply = `{"errno":0,"list":[{"fs_id":9007199254740994,"path":"/Library/Comics/漫画 #?%.PDF","size":3145925}]}`
		default:
			t.Fatal("directory scan or unexpected API", r.URL.Path, q.Get("method"))
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(reply)), Request: r}, nil
	}))
	base.NoRedirectClient.SetTransport(playerSearchTransport(func(r *http.Request) (*http.Response, error) {
		heads++
		if r.Method != "HEAD" || r.Header.Get("User-Agent") != "pan.baidu.com" || r.URL.Query().Get("access_token") != "fixture" {
			t.Fatal("ticket request changed")
		}
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{"https://fixture.invalid/original.pdf"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})).SetRedirectPolicy(resty.RedirectPolicyFunc(func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }))
	for _, id := range []string{"9007199254740994", ""} {
		obj, link, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", id)
		if err != nil || obj.GetID() != "9007199254740994" || obj.GetName() != "漫画 #?%.PDF" || link.Header.Get("User-Agent") != "pan.baidu.com" {
			t.Fatal(err)
		}
	}
	if metas != 2 || searches != 1 || heads != 2 {
		t.Fatal(metas, searches, heads)
	}
	changed = true
	if _, _, err := d.PlayerArchiveTarget(context.Background(), "/Comics/漫画 #?%.PDF", "9007199254740994"); err == nil || heads != 2 {
		t.Fatal("moved object issued ticket")
	}
}
