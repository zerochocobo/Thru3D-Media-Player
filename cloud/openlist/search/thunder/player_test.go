package thunder

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
)

type playerTransport func(*http.Request) (*http.Response, error)

func (f playerTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func playerFixture(t *testing.T, handle func(*http.Request) (string, error)) {
	t.Helper()
	previous := playerClientFactory
	playerClientFactory = func() *resty.Client {
		return resty.New().SetTransport(playerTransport(func(r *http.Request) (*http.Response, error) {
			body, err := handle(r)
			if err != nil {
				return nil, err
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
		}))
	}
	EnablePlayer(true)
	t.Cleanup(func() { playerClientFactory = previous; EnablePlayer(false) })
}
func TestPlayerThunderLoginPagesRangeRestart(t *testing.T) {
	logins, refreshes, pages := 0, 0, 0
	payload := bytes.Repeat([]byte("thunder-original-seek"), 1000)
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("User-Agent") == "" {
			t.Error("media credential/UA boundary")
		}
		http.ServeContent(w, r, "movie.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer media.Close()
	expired := false
	playerFixture(t, func(r *http.Request) (string, error) {
		switch r.URL.Host + r.URL.Path {
		case "xluser-ssl.xunlei.com/xluser.core.login/v3/login":
			logins++
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			if body["userName"] != "fixture" || body["passWord"] != "fixture-password" {
				t.Error("wrong password request")
			}
			return `{"sessionID":"fixture-session","userID":"123"}`, nil
		case "xluser-ssl.xunlei.com/v1/shield/captcha/init":
			return `{"captcha_token":"captcha-fixture"}`, nil
		case "xluser-ssl.xunlei.com/v1/auth/signin/token":
			return `{"access_token":"access-initial","refresh_token":"refresh-initial","token_type":"Bearer","user_id":"123"}`, nil
		case "xluser-ssl.xunlei.com/v1/auth/token":
			refreshes++
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			expected := "refresh-initial"
			if refreshes > 1 {
				expected = fmt.Sprintf("refresh-%d", refreshes-1)
			}
			if body["refresh_token"] != expected {
				t.Error("rotated refresh token not reused")
			}
			return fmt.Sprintf(`{"access_token":"access-%d","refresh_token":"refresh-%d","token_type":"Bearer","user_id":"123"}`, refreshes, refreshes), nil
		case "api-pan.xunlei.com/drive/v1/files":
			pages++
			if r.URL.Query().Get("limit") != "100" {
				t.Error("not a bounded native page")
			}
			if !expired {
				expired = true
				return `{"error_code":16,"error":"expired"}`, nil
			}
			if r.Header.Get("Authorization") != "Bearer access-2" {
				t.Error("refreshed access token not used")
			}
			if r.URL.Query().Get("page_token") == "" {
				return `{"files":[{"id":"folder","name":"Folder","kind":"drive#folder"},{"id":"video","name":"movie.mp4","size":"20000","kind":"drive#file"}],"next_page_token":"second"}`, nil
			}
			return `{"files":[{"id":"last","name":"Last","kind":"drive#folder"}]}`, nil
		case "api-pan.xunlei.com/drive/v1/files/video":
			if !r.URL.Query().Has("space") || r.URL.Query().Get("space") != "" {
				t.Error("upstream Thunder space parameter missing")
			}
			return fmt.Sprintf(`{"id":"video","name":"movie.mp4","kind":"drive#file","web_content_link":%q}`, media.URL+"/original.mp4"), nil
		default:
			return "", fmt.Errorf("unexpected fixture endpoint")
		}
	})
	result, err := PlayerLogin(context.Background(), PlayerLoginRequest{Username: "fixture", Password: "fixture-password"})
	if err != nil || result.Credential == nil {
		t.Fatal("login", err)
	}
	encoded, _ := json.Marshal(result.Credential)
	if strings.Contains(string(encoded), "username") || strings.Contains(string(encoded), "password") || strings.Contains(string(encoded), "fixture-session") {
		t.Fatal("username/password/session persisted")
	}
	d := &PlayerThunder{PlayerCredential: *result.Credential}
	if err = d.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	root, _ := d.PlayerFolder(context.Background(), "/", "")
	first, next, _, err := d.PlayerPageSized(context.Background(), root, "", "source", 2)
	if err != nil || len(first) != 2 || next == "" || pages != 2 {
		t.Fatal("first page/refresh", err, pages)
	}
	second, next, _, err := d.PlayerPageSized(context.Background(), root, next, "source", 2)
	if err != nil || len(second) != 1 || next != "" {
		t.Fatal("second page", err)
	}
	link, err := d.Link(context.Background(), first[1], model.LinkArgs{})
	if err != nil {
		t.Fatal(err)
	}
	if link.RangeReader != nil || link.Header.Get("User-Agent") != d.DownloadUserAgent {
		t.Fatal("playback must reuse upstream URL/UA and the common proxy")
	}
	for _, span := range [][2]int{{0, 63}, {16000, 16063}, {500, 563}} {
		request, _ := http.NewRequest("GET", link.URL, nil)
		request.Header = link.Header.Clone()
		request.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", span[0], span[1]))
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if response.StatusCode != 206 || !bytes.Equal(got, payload[span[0]:span[1]+1]) {
			t.Fatal("forward/backward exact range failed")
		}
	}
	saved, _ := json.Marshal(d.PlayerCredential)
	// Old mounts can still contain a username; decoding and the normal save must drop it.
	var legacy map[string]any
	json.Unmarshal(saved, &legacy)
	legacy["username"] = "legacy-user"
	saved, _ = json.Marshal(legacy)
	var restored PlayerCredential
	if err = json.Unmarshal(saved, &restored); err != nil {
		t.Fatal(err)
	}
	sanitized, _ := json.Marshal(restored)
	if strings.Contains(string(sanitized), "username") || strings.Contains(string(sanitized), "legacy-user") {
		t.Fatal("legacy username retained")
	}
	restarted := &PlayerThunder{PlayerCredential: restored}
	if err = restarted.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	if logins != 1 || refreshes != 3 || restarted.PlayerCredential.RefreshToken != "refresh-3" {
		t.Fatal("restart did not renew without password", logins, refreshes)
	}
}
func TestPlayerThunderVerificationAndCapabilityGate(t *testing.T) {
	playerFixture(t, func(r *http.Request) (string, error) {
		if r.URL.Host != "xluser-ssl.xunlei.com" {
			return "", fmt.Errorf("unexpected endpoint")
		}
		return `{"error_code":4126,"error":"review_panel","creditkey":"private-credit","reviewurl":"https://i.xunlei.com/xlcaptcha/vertifyPhone.html?event=login3"}`, nil
	})
	result, err := PlayerLogin(context.Background(), PlayerLoginRequest{Username: "fixture", Password: "fixture-password"})
	if err != nil || result.Challenge == nil || result.Challenge.Kind != "review" || result.Credential != nil {
		t.Fatal("review challenge", err)
	}
	if PlayerVerificationURL("https://xunlei.com.evil.invalid/") || PlayerVerificationURL("http://i.xunlei.com/") {
		t.Fatal("untrusted verification URL")
	}
	EnablePlayer(false)
	if _, err = PlayerLogin(context.Background(), PlayerLoginRequest{Username: "fixture", Password: "fixture-password"}); err == nil {
		t.Fatal("disabled capability allowed login")
	}
	if err = (&PlayerThunder{}).Init(context.Background()); err == nil {
		t.Fatal("disabled capability loaded mount")
	}
}
func TestPlayerThunderRepeatedExpiryStops(t *testing.T) {
	calls := 0
	playerFixture(t, func(r *http.Request) (string, error) {
		calls++
		if strings.HasSuffix(r.URL.Path, "/auth/token") {
			return `{"access_token":"a","refresh_token":"r","token_type":"Bearer"}`, nil
		}
		return `{"error_code":16,"error":"expired","error_description":"private-content"}`, nil
	})
	d := &PlayerThunder{PlayerCredential: PlayerCredential{RefreshToken: "r", DeviceID: strings.Repeat("a", 32)}}
	if err := d.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, _, _, err := d.PlayerPageSized(context.Background(), &model.Object{IsFolder: true}, "", "source", 2)
	if err == nil || calls != 6 || strings.Contains(err.Error(), "private-content") {
		t.Fatal("unbounded retry or response leak", calls, err)
	}
}

func TestPlayerThunderColdPlaybackVerifiesParentChainWithoutListing(t *testing.T) {
	playerFixture(t, func(r *http.Request) (string, error) {
		switch r.URL.Path {
		case "/v1/auth/token":
			return `{"access_token":"a","refresh_token":"r","token_type":"Bearer"}`, nil
		case "/drive/v1/files/video":
			return `{"id":"video","parent_id":"parent","name":"movie.mkv","kind":"drive#file","size":"100"}`, nil
		case "/drive/v1/files/parent":
			return `{"id":"parent","parent_id":"","name":"Folder","kind":"drive#folder"}`, nil
		default:
			t.Fatal("cold playback enumerated a directory or requested an unexpected ID")
			return "", nil
		}
	})
	d := &PlayerThunder{PlayerCredential: PlayerCredential{RefreshToken: "r", DeviceID: strings.Repeat("a", 32)}}
	if err := d.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	file, _, err := d.PlayerArchiveTarget(context.Background(), "/Folder/movie.mkv", "video")
	if err != nil || file.GetID() != "video" || file.GetSize() != 100 {
		t.Fatal("cold playback failed", err)
	}
	for _, remote := range []string{"/Other/movie.mkv", "/movie.mkv", "/Folder/other.mkv"} {
		if _, _, err = d.PlayerArchiveTarget(context.Background(), remote, "video"); err == nil {
			t.Fatal("moved/renamed object accepted")
		}
	}
}
func TestPlayerThunderSplitsNativeBatchAndRejectsChangedContinuation(t *testing.T) {
	changed := false
	playerFixture(t, func(r *http.Request) (string, error) {
		if strings.HasSuffix(r.URL.Path, "/auth/token") {
			return `{"access_token":"a","refresh_token":"r","token_type":"Bearer"}`, nil
		}
		if r.URL.Query().Get("limit") != "100" {
			t.Fatal("small API limit must not lose overflow rows")
		}
		first := "one"
		if changed {
			first = "new"
		}
		return fmt.Sprintf(`{"files":[{"id":%q,"name":"one","kind":"drive#folder"},{"id":"two","name":"two","kind":"drive#file"},{"id":"three","name":"three","kind":"drive#file"},{"id":"four","name":"four","kind":"drive#file"}]}`, first), nil
	})
	d := &PlayerThunder{PlayerCredential: PlayerCredential{RefreshToken: "r", DeviceID: strings.Repeat("a", 32)}}
	if err := d.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	root := &model.Object{IsFolder: true}
	first, next, _, err := d.PlayerPageSized(context.Background(), root, "", "source", 2)
	if err != nil || len(first) != 2 || first[1].GetID() != "two" || next == "" {
		t.Fatal("first slice", err)
	}
	last, end, _, err := d.PlayerPageSized(context.Background(), root, next, "source", 2)
	if err != nil || len(last) != 2 || last[0].GetID() != "three" || last[1].GetID() != "four" || end != "" {
		t.Fatal("overflow lost", err)
	}
	changed = true
	if _, _, _, err := d.PlayerPageSized(context.Background(), root, next, "source", 2); err == nil || !strings.Contains(err.Error(), "directory page expired") {
		t.Fatal("changed page was silently reused", err)
	}
}

func TestPlayerThunderUsesPlayUsageWithoutReplacingOriginalFile(t *testing.T) {
	usage := ""
	playerFixture(t, func(r *http.Request) (string, error) {
		switch r.URL.Path {
		case "/v1/auth/token":
			return `{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","user_id":"123"}`, nil
		case "/drive/v1/files/video":
			usage = r.URL.Query().Get("usage")
			if !r.URL.Query().Has("space") || r.Header.Get("Authorization") != "Bearer access" {
				t.Error("authorized file lookup context changed")
			}
			original := "https://media.example.invalid/download-original"
			if usage == "PLAY" {
				original = "https://media.example.invalid/play-original"
			}
			return fmt.Sprintf(`{"id":"video","kind":"drive#file","size":"20000","web_content_link":%q,"medias":[{"link":{"url":"https://media.example.invalid/transcoded","size":"10000"}}]}`, original), nil
		}
		return "", fmt.Errorf("unexpected fixture endpoint")
	})
	d := &PlayerThunder{PlayerCredential: PlayerCredential{RefreshToken: "refresh", DeviceID: strings.Repeat("a", 32)}}
	if err := d.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"film.mp4", "film #1.MKV", "film.mk3d", "film.vob", "audio.flac", "audio.dtshd", "disc.iso", "book.pdf", "book.cbz", "files.zip"} {
		expected := ""
		if strings.HasSuffix(name, ".mp4") || strings.HasSuffix(name, ".MKV") || strings.HasSuffix(name, ".mk3d") || strings.HasSuffix(name, ".vob") || strings.HasPrefix(name, "audio.") {
			expected = "PLAY"
		}
		file := &model.Object{ID: "video", Name: name, Size: 20000}
		link, err := d.Link(context.Background(), file, model.LinkArgs{})
		if err != nil || usage != expected {
			t.Fatalf("wrong link usage for %s: %q, %v", name, usage, err)
		}
		suffix := "/download-original"
		if expected == "PLAY" {
			suffix = "/play-original"
		}
		if !strings.HasSuffix(link.URL, suffix) || file.GetSize() != 20000 || link.RangeReader != nil || link.Header.Get("User-Agent") != d.DownloadUserAgent {
			t.Fatal("original file identity or transport was replaced")
		}
	}
}
