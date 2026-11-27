package cloudcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
	"golang.org/x/net/webdav"
)

const slowAccount = "/11111111-1111-1111-1111-111111111111"
const fastAccount = "/22222222-2222-2222-2222-222222222222"

func isolationJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func TestIndependentCloudAccounts(t *testing.T) {
	folder := t.TempDir()
	if err := os.WriteFile(filepath.Join(folder, "fixture.mp4"), []byte("0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	dav := httptest.NewServer(&webdav.Handler{FileSystem: webdav.Dir(folder), LockSystem: webdav.NewMemLS()})
	defer dav.Close()
	data := t.TempDir()
	for _, phase := range []string{"warm", "restart"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestCloudIsolationChild$", "-test.v")
		cmd.Env = append(os.Environ(), "VRPP_ISOLATION_PHASE="+phase, "VRPP_ISOLATION_DATA="+data, "VRPP_ISOLATION_DAV="+dav.URL)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%s: %v\n%s", phase, err, out)
		}
		for _, line := range strings.Split(string(out), "\n") {
			if strings.Contains(line, "healthy browse") {
				t.Log(line)
			}
		}
	}
}

func TestCloudIsolationChild(t *testing.T) {
	phase := os.Getenv("VRPP_ISOLATION_PHASE")
	if phase == "" {
		t.Skip("fresh process fixture")
	}
	if err := Start(os.Getenv("VRPP_ISOLATION_DATA"), strings.Repeat("ea", 32)); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ConfigureRequestDiagnostics(true)
	var stalled atomic.Bool
	entered := make(chan struct{})
	abandoned := make(chan struct{})
	release := make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	base.RestyClient.SetTransport(baiduTransport(func(r *http.Request) (*http.Response, error) {
		status, body := 200, ""
		switch r.URL.Path {
		case "/rotate":
			close(entered)
			// The provider may already have rotated the token: keep waiting for its
			// answer even after the caller leaves, as a slow network would.
			<-release
			if err := r.Context().Err(); err != nil {
				close(abandoned)
				return nil, err
			}
			body = "{\"refresh_token\":\"rotated-" + phase + "\",\"access_token\":\"rotated-access\"}"
		case "/adrive/v1.0/user/getDriveInfo", "/adrive/v1.0/openFile/list":
			if stalled.Load() {
				status, body = 401, reqExpired
			} else if strings.HasSuffix(r.URL.Path, "getDriveInfo") {
				body = driveInfo
			} else {
				body = "{\"items\":[]}"
			}
		default:
			return nil, errors.New("unexpected fixture request")
		}
		return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	}))
	call := func(kind string, id int64, route string, args map[string]any) map[string]any {
		t.Helper()
		key, err := NewTrackedRequest(kind, id)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := RequestCancelable("POST", route, isolationJSON(args), key)
		if err != nil {
			t.Fatal(route, err)
		}
		var res struct {
			Code int
			Data map[string]any
		}
		if json.Unmarshal([]byte(raw), &res) != nil || res.Code != 200 {
			t.Fatal(route, res.Code)
		}
		return res.Data
	}
	create := func(driver, mount string, addition map[string]any) {
		call("background", 0, "/create", map[string]any{"driver": driver, "mount_path": mount, "addition": isolationJSON(addition), "web_proxy": true})
	}
	if phase == "warm" {
		create("WebDav", fastAccount, map[string]any{"address": os.Getenv("VRPP_ISOLATION_DAV"), "root_folder_path": "/", "vendor": "other"})
		create("AliyundriveOpen", slowAccount, map[string]any{"root_folder_id": "root", "drive_type": "default", "AccessToken": "fixture-access", "refresh_token": "fixture-refresh", "use_online_api": true, "api_url_address": "https://fixture.invalid/rotate"})
	} else if knownMount(slowAccount).pending.Load() == 0 || knownMount(fastAccount).pending.Load() == 0 {
		t.Fatal("both saved accounts should await first use")
	}
	page := func(mount string) map[string]any {
		return map[string]any{"mount": mount, "path": "/", "refresh": true, "order": "source"}
	}
	stalled.Store(true)
	owner, route, body := "browse", "/directory", page(slowAccount)
	if phase == "restart" {
		owner, route, body = "playback", "/archive-stream", map[string]any{"mount": slowAccount, "path": "/fixture.mp4", "id": "/fixture.mp4", "resolve_path": true}
	}
	key, _ := NewTrackedRequest(owner, 17)
	slow := make(chan error, 1)
	go func() { _, err := RequestCancelable("POST", route, isolationJSON(body), key); slow <- err }()
	awaitFixture(t, entered, "renewal did not reach the transport")
	fast := func() {
		t.Helper()
		started := time.Now()
		rows := call("browse", 18, "/directory", page(fastAccount))["content"].([]any)
		if len(rows) != 1 || rows[0].(map[string]any)["name"] != "fixture.mp4" {
			t.Fatal("missing healthy directory")
		}
		data := call("playback", 19, "/archive-stream", map[string]any{"mount": fastAccount, "path": "/fixture.mp4", "id": "/fixture.mp4", "resolve_path": true})
		req, err := http.NewRequest("GET", data["stream"].(string), nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Range", "bytes=4-7")
		client := http.Client{Timeout: 3 * time.Second}
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(res.Body)
		res.Body.Close()
		if err != nil || res.StatusCode != 206 || string(b) != "4567" {
			t.Fatal("healthy media range")
		}
		if time.Since(started) > 3*time.Second {
			t.Fatal("healthy account waited")
		}
		t.Logf("%s healthy browse + playback range completed in %d ms", phase, time.Since(started).Milliseconds())
	}
	fast()
	CancelRequest(key)
	select {
	case err := <-slow:
		if !errors.Is(err, context.Canceled) {
			t.Fatal("old caller", err)
		}
	case <-time.After(time.Second):
		t.Fatal("old caller waited for driver unwind")
	}
	fast()
	stalled.Store(false)
	close(release)
	deadline := time.Now().Add(4 * time.Second)
	for {
		row, err := db.GetStorageByMountPath(slowAccount)
		if err == nil && strings.Contains(row.Addition, "rotated-"+phase) {
			break
		}
		select {
		case <-abandoned:
			t.Fatal("cancelled caller abandoned an accepted token exchange")
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("rotated refresh token was not saved")
		}
		time.Sleep(20 * time.Millisecond)
	}
	call("browse", 20, "/directory", page(slowAccount))
	trace := RequestDiagnostics()
	for _, fragment := range []string{"driver=AliyundriveOpen", "driver=WebDav", "stage=caller_cancelled", "stage=released", "stage=http_send attempt=1", "operation=token_refresh", "stage=wire_sent", fmt.Sprintf("%s=17", owner), "playback=19", "browse=18"} {
		if !strings.Contains(trace, fragment) {
			t.Fatal("missing diagnostic", fragment)
		}
	}
	for _, secret := range []string{slowAccount, fastAccount, "fixture", "https://", "http://", "refresh_ui"} {
		if strings.Contains(trace, secret) {
			t.Fatal("private request data in diagnostic")
		}
	}
	ConfigureRequestDiagnostics(false)
	if RequestDiagnostics() != "" {
		t.Fatal("private diagnostics retained after opt-out")
	}
	if phase == "restart" {
		// A saved account with invalid settings must still accept corrected credentials.
		row, err := db.GetStorageByMountPath(fastAccount)
		if err != nil {
			t.Fatal(err)
		}
		valid := row.Addition
		row.Addition = "{"
		if err := db.UpdateStorage(row); err != nil {
			t.Fatal(err)
		}
		q := knownMount(fastAccount)
		q.pending.Store(uint32(row.ID))
		call("background", 0, "/update", map[string]any{"id": row.ID, "driver": row.Driver, "mount_path": fastAccount, "addition": valid, "web_proxy": true})
		if q.pending.Load() != 0 {
			t.Fatal("repaired account still waiting for initialization")
		}
		call("browse", 21, "/directory", page(fastAccount))
	}
}

func awaitFixture(t *testing.T, ch <-chan struct{}, message string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(4 * time.Second):
		t.Fatal(message)
	}
}

const reqExpired = "{\"code\":\"AccessTokenExpired\"}"
const driveInfo = "{\"user_id\":\"fixture\",\"default_drive_id\":\"drive\"}"
