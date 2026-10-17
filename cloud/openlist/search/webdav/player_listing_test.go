package webdav

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestPlayerWebDAVReusesSingleDirectoryResponseAcrossPagesAndSorts(t *testing.T) {
	playerDAVCache = map[playerDAVKey]*playerDAVSnapshot{}
	defer func() { playerDAVCache = map[playerDAVKey]*playerDAVSnapshot{} }()
	var reads atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PROPFIND" || r.Header.Get("Depth") != "1" {
			t.Error("unexpected request", r.Method)
			w.WriteHeader(500)
			return
		}
		reads.Add(1)
		w.Header().Set("Content-Type", "application/xml")
		w.WriteHeader(207)
		fmt.Fprint(w, `<d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`)
		for i := 8000; i >= 1; i-- {
			fmt.Fprintf(w, `<d:response><d:href>/movie%d.mp4</d:href><d:propstat><d:prop><d:getcontentlength>%d</d:getcontentlength><d:getlastmodified>Sat, 17 Oct 2026 00:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`, i, i)
		}
		fmt.Fprint(w, `</d:multistatus>`)
	}))
	defer server.Close()
	d := &WebDav{}
	d.Storage.ID = 7
	d.Address = server.URL
	d.RootFolderPath = "/"
	if err := d.setClient(); err != nil {
		t.Fatal(err)
	}
	dir, _ := d.PlayerFolder(context.Background(), "/", "")
	first, next, total, err := d.PlayerPage(context.Background(), dir, "", "name_asc")
	if err != nil || len(first) != 48 || first[0].GetName() != "movie1.mp4" || next != "48" || total != 8000 || reads.Load() != 1 {
		t.Fatal(err, len(first), next, total, reads.Load())
	}
	second, _, _, err := d.PlayerPage(context.Background(), dir, next, "name_asc")
	if err != nil || second[0].GetName() != "movie49.mp4" || reads.Load() != 1 {
		t.Fatal(err, reads.Load())
	}
	for _, order := range []string{"name_desc", "size_asc", "size_desc", "modified_asc", "modified_desc", "source"} {
		if _, _, _, err = d.PlayerPage(context.Background(), dir, "", order); err != nil || reads.Load() != 1 {
			t.Fatal("sort reread entire response", order, err, reads.Load())
		}
	}
	d.PlayerForget("/")
	d.PlayerPage(context.Background(), dir, "", "name_asc")
	if reads.Load() != 2 {
		t.Fatal("refresh retained stale listing")
	}
	PlayerDropStorage(8)
	if len(playerDAVCache) != 1 {
		t.Fatal("disconnect discarded another account's snapshot")
	}
	PlayerDropStorage(7)
	if len(playerDAVCache) != 0 {
		t.Fatal("disconnect retained a snapshot after directory session eviction")
	}
}

func TestPlayerWebDAVCancellationClosesTheNetworkRequest(t *testing.T) {
	started, finished := make(chan struct{}), make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		close(started)
		select {
		case <-r.Context().Done():
		case <-release:
		}
		close(finished)
	}))
	defer server.Close()
	defer close(release)
	d := &WebDav{}
	d.Address = server.URL
	d.RootFolderPath = "/"
	if err := d.setClient(); err != nil {
		t.Fatal(err)
	}
	dir, _ := d.PlayerFolder(context.Background(), "/", "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, _, _, err := d.PlayerPage(ctx, dir, "", "source"); done <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("DAV request not started")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled listing succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("cancel did not stop ReadDir")
	}
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("DAV server still has an open request")
	}
}
