package gowebdav

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
