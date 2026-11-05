package cloudcore

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
)

// Real pinned driver + encrypted database + cursor router + Range proxy. All
// provider requests are intercepted; no account or live token is used.
func assert123Core(t *testing.T, call func(string, string, any) map[string]any) {
	t.Run("123OfficialOAuthBrowseAndRange", func(t *testing.T) {
		payload := bytes.Repeat([]byte("123-original-fixture"), 4096)
		reads := 0
		media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "" {
				t.Error("OAuth token leaked to media")
			}
			reads++
			http.ServeContent(w, r, "film.mp4", time.Unix(0, 0), bytes.NewReader(payload))
		}))
		defer media.Close()
		original := base.RestyClient.GetClient().Transport
		defer func() { base.RestyClient.GetClient().Transport = original }()
		renewals := 0
		base.RestyClient.GetClient().Transport = baiduTransport(func(r *http.Request) (*http.Response, error) {
			body := ""
			if r.URL.Host == "api.oplist.org" && r.URL.Path == "/123cloud/renewapi" {
				if r.URL.Query().Get("driver_txt") != "123cloud_oa" || r.URL.Query().Get("server_use") != "true" || r.URL.Query().Get("refresh_ui") != "123-refresh-fixture" {
					t.Error("wrong official renewal parameters")
				}
				renewals++
				body = `{"access_token":"123-access-rotated","refresh_token":"123-refresh-rotated","expires_in":7200}`
			} else if r.URL.Host == "open-api.123pan.com" {
				if r.Header.Get("Authorization") != "Bearer 123-access-rotated" || r.Header.Get("platform") != "open_platform" {
					t.Error("official access token not used")
				}
				switch r.URL.Path {
				case "/api/v2/file/list":
					if r.URL.Query().Get("parentFileId") != "0" {
						t.Error("wrong root")
					}
					body = fmt.Sprintf(`{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":42,"filename":"中文 #%%.mp4","size":%d,"type":0,"trashed":0}]}}`, len(payload))
				case "/api/v1/file/download_info":
					if r.URL.Query().Get("fileId") != "42" {
						t.Error("wrong media identity")
					}
					body = fmt.Sprintf(`{"code":0,"data":{"downloadUrl":%q}}`, media.URL+"/original.mp4")
				default:
					return nil, fmt.Errorf("unexpected 123 API fixture request")
				}
			} else {
				return nil, fmt.Errorf("unexpected external fixture request")
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
		})
		const mount = "/12345678-1234-1234-1234-123456789123"
		addition, _ := json.Marshal(map[string]any{"root_folder_id": "0", "AccessToken": "123-access-fixture", "RefreshToken": "123-refresh-fixture", "use_online_api": true, "api_url_address": "https://api.oplist.org/123cloud/renewapi", "DirectLink": false})
		created := call("POST", "/create", map[string]any{"mount_path": mount, "driver": "123 Open", "addition": string(addition), "web_proxy": true, "disabled": false})
		id := int(created["data"].(map[string]any)["id"].(float64))
		defer call("POST", "/delete?id="+fmtInt(id), nil)
		page := call("POST", "/directory", map[string]any{"mount": mount, "path": "/", "page_size": 100, "order": "source"})["data"].(map[string]any)
		rows := page["content"].([]any)
		if len(rows) != 1 || rows[0].(map[string]any)["id"] != "42" || page["next_offset"] != float64(-1) || reads != 0 || renewals != 1 {
			t.Fatal("123 directory contract failed", page)
		}
		var stored string
		if err := db.GetDb().Raw("SELECT addition FROM x_storages WHERE id = ?", id).Scan(&stored).Error; err != nil {
			t.Fatal(err)
		}
		loaded, err := db.GetStorageById(uint(id))
		if err != nil || !strings.HasPrefix(stored, "vrpp1:") || strings.Contains(stored, "123-refresh") || !strings.Contains(loaded.Addition, "123-refresh-rotated") {
			t.Fatal("123 rotated token storage failed", err)
		}
		link, err := Stream(mount + "/中文 #%.mp4")
		if err != nil {
			t.Fatal(err)
		}
		req, _ := http.NewRequest("GET", link, nil)
		req.Header.Set("Range", "bytes=4-23")
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || response.StatusCode != 206 || !bytes.Equal(body, payload[4:24]) {
			t.Fatal("123 original range failed", response.StatusCode, err)
		}
	})
}
