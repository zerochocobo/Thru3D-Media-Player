package gowebdav

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPlayerBodyRejectsExcessBeforeUnlimitedAllocation(t *testing.T) {
	body := &playerBoundedBody{io.NopCloser(strings.NewReader(strings.Repeat("x", 100))), 32}
	data, err := io.ReadAll(body)
	if err == nil || len(data) != 32 {
		t.Fatal(len(data), err)
	}
}

func TestPlayerReadDirStopsAtRecordLimit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(207)
		fmt.Fprint(w, `<d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`)
		for i := 0; i < 20001; i++ {
			if _, err := fmt.Fprintf(w, `<d:response><d:href>/%d.mp4</d:href><d:propstat><d:prop><d:displayname>x</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`, i); err != nil {
				return
			}
		}
		fmt.Fprint(w, `</d:multistatus>`)
	}))
	defer server.Close()
	client := NewClient(server.URL, "", "")
	files, err := client.PlayerReadDir(context.Background(), "/")
	if err == nil || len(files) > 20000 || !strings.Contains(err.Error(), "metadata limit") {
		t.Fatal(len(files), err)
	}
}

func TestPlayerColdStatCancelsAtServer(t *testing.T) {
	entered, disconnected := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Read the PROPFIND body so the server observes a disconnected HTTP/1 caller.
		_, _ = io.Copy(io.Discard, r.Body)
		close(entered)
		select {
		case <-r.Context().Done():
			close(disconnected)
		case <-time.After(4 * time.Second):
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := NewClient(server.URL, "", "").PlayerStat(ctx, "/cold.mp4"); done <- err }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("stat did not reach DAV")
	}
	cancel()
	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("DAV stat connection kept running")
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("stat succeeded after cancellation")
		}
	case <-time.After(time.Second):
		t.Fatal("stat blocked caller")
	}
}
