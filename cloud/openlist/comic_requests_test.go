package cloudcore

import (
	stdzip "archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestComicOverlappingRangesOnlyFetchMissingBytes(t *testing.T) {
	payload := bytes.Repeat([]byte{42}, 4096)
	var spans [][2]int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var start, end int64
		fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end)
		spans = append(spans, [2]int64{start, end})
		http.ServeContent(w, r, "data", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer server.Close()
	s, e := newComicSource(context.Background(), server.URL)
	if e != nil {
		t.Fatal(e)
	}
	spans = nil
	if e = s.prime(1024, 1024); e != nil {
		t.Fatal(e)
	}
	if e = s.prime(512, 2048); e != nil {
		t.Fatal(e)
	}
	p := make([]byte, 2048)
	if n, e := s.ReadAt(p, 512); e != nil || n != len(p) {
		t.Fatal(n, e)
	}
	want := [][2]int64{{1024, 2047}, {512, 1023}, {2048, 2559}}
	if fmt.Sprint(spans) != fmt.Sprint(want) {
		t.Fatal("cached bytes were fetched again", spans)
	}
}

func TestComicSmallPageRangeCacheIsBounded(t *testing.T) {
	const size = 256 << 20
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var start, end int64
		fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end)
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
		w.WriteHeader(206)
		w.Write(make([]byte, end-start+1))
	}))
	defer server.Close()
	s, e := newComicSource(context.Background(), server.URL)
	if e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 200; i++ {
		if e = s.prime(int64(i*(128<<10)), 128<<10); e != nil {
			t.Fatal(e)
		}
	}
	used := 0
	for _, block := range s.blocks {
		used += len(block.data)
	}
	if used > 16<<20 || len(s.blocks) > 128 {
		t.Fatal("small archive pages grew range memory without bound", used, len(s.blocks))
	}
}

func TestComicCancelledLargePageRetainsCompletedRanges(t *testing.T) {
	payload := bytes.Repeat([]byte{42}, 10<<20)
	blocked := make(chan struct{})
	var once atomic.Bool
	var mu sync.Mutex
	var spans [][2]int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var start, end int64
		fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end)
		mu.Lock()
		spans = append(spans, [2]int64{start, end})
		mu.Unlock()
		if start == 4<<20 && once.CompareAndSwap(false, true) {
			close(blocked)
			<-r.Context().Done()
			return
		}
		http.ServeContent(w, r, "data", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s, e := newComicSource(ctx, server.URL)
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() { done <- s.prime(0, int64(len(payload))) }()
	select {
	case <-blocked:
	case <-time.After(5 * time.Second):
		t.Fatal("page never reached cancellable second chunk")
	}
	cancel()
	if e = <-done; !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	if len(s.payload.data) != 4<<20 {
		t.Fatal("completed page range discarded", len(s.payload.data))
	}
	s.ctx = context.Background()
	if e = s.prime(0, int64(len(payload))); e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(s.payload.data, payload) {
		t.Fatal("resumed compressed bytes changed")
	}
	first := 0
	mu.Lock()
	for _, span := range spans {
		if span == [2]int64{0, (4 << 20) - 1} {
			first++
		}
	}
	mu.Unlock()
	if first != 1 {
		t.Fatal("cancelled page restarted already completed bytes", first)
	}
}

func TestComicPageCacheKeepsRecentlyRevisitedPages(t *testing.T) {
	var archive bytes.Buffer
	zw := stdzip.NewWriter(&archive)
	payload := bytes.Repeat([]byte{42}, 2<<20)
	for i := 0; i < 4; i++ {
		w, e := zw.CreateHeader(&stdzip.FileHeader{Name: fmt.Sprintf("%d.png", i), Method: stdzip.Store})
		if e != nil {
			t.Fatal(e)
		}
		if _, e = w.Write(payload); e != nil {
			t.Fatal(e)
		}
	}
	if e := zw.Close(); e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "book.zip", time.Unix(0, 0), bytes.NewReader(archive.Bytes()))
	}))
	defer server.Close()
	s, e := newComicSource(context.Background(), server.URL)
	if e != nil {
		t.Fatal(e)
	}
	c, e := comicIndex(s, "book.zip", "")
	if e != nil {
		t.Fatal(e)
	}
	c.dir = t.TempDir()
	for _, page := range []int{0, 1, 2, 0, 3} {
		if _, e = c.page(page); e != nil {
			t.Fatal(e)
		}
	}
	if c.cached[0] == "" || c.cached[1] != "" || c.cached[2] == "" || c.cached[3] == "" {
		t.Fatal("recent page was evicted", c.recent)
	}
	reads := s.reads
	path, e := c.page(0)
	if e != nil {
		t.Fatal(e)
	}
	if s.reads != reads {
		t.Fatal("recently revisited page used network")
	}
	if _, e = os.Stat(path); e != nil {
		t.Fatal(e)
	}
}

func TestComicRemoteIndexStopsBeforeAnUnboundedHeaderScan(t *testing.T) {
	const size = 256 << 20
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests++; w.WriteHeader(500) }))
	defer server.Close()
	s := &comicSource{ctx: context.Background(), url: server.URL, size: size, client: server.Client(), remote: true, indexing: true, reads: comicMaxRemoteIndexReads}
	if _, e := s.fetch(0, 1); !errors.Is(e, errComicLimit) {
		t.Fatal("remote index request cap ignored", e)
	}
	s.reads = 0
	s.bytes = comicMaxRemoteIndexBytes
	if _, e := s.fetch(0, 1); !errors.Is(e, errComicLimit) {
		t.Fatal("remote index byte cap ignored", e)
	}
	if requests != 0 {
		t.Fatal("over-budget index contacted provider", requests)
	}
}
