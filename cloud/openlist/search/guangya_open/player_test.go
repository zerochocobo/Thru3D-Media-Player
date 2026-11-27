package guangya_open

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

const testClient = "av7rsoJS2g0dIaXH"
const testVerifier = "0123456789abcdef0123456789abcdef0123456789abcdef"

func serve(t *testing.T, handler http.HandlerFunc) {
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	oldAPI, oldAccount := apiBase, accountBase
	apiBase, accountBase = server.URL, server.URL
	t.Cleanup(func() { apiBase, accountBase = oldAPI, oldAccount })
}

func TestPlayerGuangyaCodeExchange(t *testing.T) {
	serve(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		if r.URL.Path != "/v1/auth/token" || r.Header.Get("x-client-id") != testClient || body["grant_type"] != "authorization_code" ||
			body["code"] != "c" || body["code_verifier"] != testVerifier || body["redirect_uri"] != RedirectURI {
			t.Errorf("exchange %s %v %v", r.URL.Path, body, r.Header)
		}
		w.Write([]byte(`{"token_type":"Bearer","access_token":"a","refresh_token":"r","expires_in":1200,"sub":"u"}`))
	})
	done, err := PlayerAuth(context.Background(), PlayerAuthRequest{ClientID: testClient, Code: "c", CodeVerifier: testVerifier})
	if err != nil || done.Credential.RefreshToken != "r" || done.Credential.ClientID != testClient {
		t.Fatalf("exchange %+v %v", done, err)
	}
	for _, request := range []PlayerAuthRequest{{ClientID: "other", Code: "c", CodeVerifier: testVerifier},
		{ClientID: testClient, Code: "c", CodeVerifier: "short"}, {ClientID: testClient, CodeVerifier: testVerifier}} {
		if _, err := PlayerAuth(context.Background(), request); err == nil {
			t.Fatalf("invalid request accepted %+v", request)
		}
	}
}

func TestPlayerGuangyaCodeRejected(t *testing.T) {
	serve(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("invalid_grant")) })
	_, err := PlayerAuth(context.Background(), PlayerAuthRequest{ClientID: testClient, Code: "c", CodeVerifier: testVerifier})
	if err == nil || !strings.Contains(err.Error(), "invalid_grant") {
		t.Fatalf("rejection %v", err)
	}
}

func TestPlayerGuangyaListingAndPlayback(t *testing.T) {
	refreshes := 0
	serve(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/auth/token" {
			refreshes++
			w.Write([]byte(`{"access_token":"token` + string(rune('0'+refreshes)) + `","refresh_token":"r2","expires_in":7200}`))
			return
		}
		if r.Header.Get("x-client-id") != testClient {
			t.Errorf("missing client header")
		}
		// The first token is reported invalid once; the driver refreshes and retries.
		if r.Header.Get("Authorization") == "Bearer token1" {
			w.Write([]byte(`{"code":117,"msg":"invalid token"}`))
			return
		}
		query := r.URL.Query()
		switch r.URL.Path {
		case "/openapi/v1/file/get_file_list":
			if query.Get("pageSize") != "2" {
				t.Errorf("page size %s", query.Get("pageSize"))
			}
			if query.Get("page") == "0" {
				w.Write([]byte(`{"code":0,"data":{"total":3,"list":[{"fileId":"d1","fileName":"Movies","resType":2},` +
					`{"fileId":"f1","fileName":"a/b.mp4","resType":1,"fileSize":5}]}}`))
			} else {
				w.Write([]byte(`{"code":0,"data":{"total":3,"list":[{"fileId":"f2","fileName":"c.mp4","resType":1,"fileSize":9,"ctime":10}]}}`))
			}
		case "/openapi/v1/file/get_file_detail":
			w.Write([]byte(`{"code":0,"data":{"fileInfo":{"fileId":"f2","fileName":"c.mp4","fileSize":9,"resType":1,"depth":2}}}`))
		case "/openapi/v1/file/get_res_download_url":
			w.Write([]byte(`{"code":0,"data":{"signedURL":"https://cdn.example/c.mp4?sig=1","urlDuration":21600}}`))
		}
	})
	d := &PlayerGuangya{PlayerCredential: PlayerCredential{ClientID: testClient, RefreshToken: "r"}}
	if err := d.Init(context.Background()); err != nil || d.RefreshToken != "r2" {
		t.Fatalf("init %v", err)
	}
	root := &model.Object{IsFolder: true}
	rows, next, total, err := d.PlayerPageSized(context.Background(), root, "", "source", 2)
	if err != nil || next != "2" || total != 3 || len(rows) != 1 || rows[0].GetName() != "Movies" || !rows[0].IsDir() {
		t.Fatalf("first page %v %q %d %v", rows, next, total, err)
	}
	if refreshes != 2 {
		t.Fatalf("expected one retry refresh, got %d refreshes", refreshes)
	}
	rows, next, _, err = d.PlayerPageSized(context.Background(), root, next, "source", 2)
	if err != nil || next != "" || len(rows) != 1 || rows[0].GetID() != "f2" {
		t.Fatalf("second page %v %q %v", rows, next, err)
	}
	if _, _, _, err := d.PlayerPageSized(context.Background(), root, "3", "source", 2); err == nil {
		t.Fatal("unaligned cursor accepted")
	}
	file, _, err := d.PlayerArchiveTarget(context.Background(), "/Movies/c.mp4", "f2")
	if err != nil || file.GetSize() != 9 {
		t.Fatalf("target %v %v", file, err)
	}
	if _, _, err := d.PlayerArchiveTarget(context.Background(), "/c.mp4", "f2"); err == nil {
		t.Fatal("moved file accepted")
	}
	link, err := d.Link(context.Background(), file, model.LinkArgs{})
	if err != nil || !strings.HasPrefix(link.URL, "https://cdn.example/") {
		t.Fatalf("link %v %v", link, err)
	}
}

func TestPlayerGuangyaRefreshFailureKeepsItsReason(t *testing.T) {
	for _, c := range []struct {
		status     int
		body, want string
	}{
		{200, `{"code":117,"msg":"free text 13100000000"}`, "guangya sign in required; refresh declined (117)"},
		{400, `{"error":"invalid_grant","error_description":"free text"}`, "guangya sign in required; refresh declined (invalid_grant)"},
		{401, `{}`, "guangya sign in required; refresh declined (HTTP 401)"},
		{502, `<html>bad gateway</html>`, "guangya sign-in unavailable (HTTP 502)"},
		{503, `{}`, "guangya sign-in unavailable (HTTP 503)"},
	} {
		serve(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(c.status); w.Write([]byte(c.body)) })
		d := &PlayerGuangya{PlayerCredential: PlayerCredential{ClientID: testClient, RefreshToken: "r"}}
		if err := d.Init(context.Background()); err == nil || err.Error() != c.want {
			t.Fatalf("%d %s: %v", c.status, c.body, err)
		}
	}
}
