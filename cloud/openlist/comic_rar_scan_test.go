package cloudcore

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"net/http"
	"os"
	"testing"
)

func comicRAR4TestHeader(kind byte, flags uint16, body []byte) []byte {
	h := []byte{0, 0, kind}
	h = binary.LittleEndian.AppendUint16(h, flags)
	h = binary.LittleEndian.AppendUint16(h, uint16(7+len(body)))
	h = append(h, body...)
	binary.LittleEndian.PutUint16(h, uint16(crc32.ChecksumIEEE(h[2:])))
	return h
}

// RAR4 has no Quick Open table. Real-sized stored pages force the decoder to
// seek between file headers, without storing a personal comic in the tests.
func comicRAR4TestBook(pages int) (comicRARSparse, []byte) {
	head := append([]byte("Rar!\x1a\x07\x00"), comicRAR4TestHeader(0x73, 0, make([]byte, 6))...)
	f := comicRARSparse{size: int64(len(head)), blocks: []comicRange{{0, head}}}
	payload := make([]byte, 256<<10)
	copy(payload, "\x89PNG\r\n\x1a\n")
	for i := 0; i < pages; i++ {
		name := fmt.Sprintf("book/%03d.png", i)
		body := binary.LittleEndian.AppendUint32(nil, uint32(len(payload)))
		body = binary.LittleEndian.AppendUint32(body, uint32(len(payload)))
		body = append(body, 2) // Win32
		body = binary.LittleEndian.AppendUint32(body, crc32.ChecksumIEEE(payload))
		body = binary.LittleEndian.AppendUint32(body, 0) // DOS time
		body = append(body, 20, 0x30)                    // RAR 2.0, stored
		body = binary.LittleEndian.AppendUint16(body, uint16(len(name)))
		body = binary.LittleEndian.AppendUint32(body, 32)
		header := comicRAR4TestHeader(0x74, 0x8000, append(body, name...))
		f.blocks = append(f.blocks, comicRange{f.size, header})
		f.size += int64(len(header))
		f.blocks = append(f.blocks, comicRange{f.size, payload})
		f.size += int64(len(payload))
	}
	end := comicRAR4TestHeader(0x7b, 0, nil)
	f.blocks = append(f.blocks, comicRange{f.size, end})
	f.size += int64(len(end))
	return f, payload
}

func TestComicRAR4SparseIndexAndRandomPages(t *testing.T) {
	f, payload := comicRAR4TestBook(173)
	s := comicRARTestSource(t, f)
	c, e := comicIndex(s, "book.cbr", "")
	if e != nil {
		t.Fatalf("ordinary RAR4 failed: %v ranges=%d bytes=%d", e, s.reads, s.bytes)
	}
	if len(c.pages) != 173 || len(s.rarHeaders) != 0 || s.reads > 175 || s.bytes > 1<<20 {
		t.Fatal("RAR4 index over-read page payloads", len(c.pages), len(s.rarHeaders), s.reads, s.bytes)
	}
	if c.pages[0].Name != "book/000.png" || c.pages[172].Name != "book/172.png" {
		t.Fatal("RAR4 page ordering changed")
	}
	if s.indexing || s.rarIndex {
		t.Fatal("RAR scan policy leaked into page extraction")
	}
	t.Logf("index ranges=%d bytes=%d pages=%d", s.reads, s.bytes, len(c.pages))
	c.dir = t.TempDir()
	for _, page := range []int{172, 0, 86} {
		filename, e := c.page(page)
		if e != nil {
			t.Fatal("RAR4 random extraction failed", page, e)
		}
		data, e := os.ReadFile(filename)
		if e != nil || !bytes.Equal(data, payload) {
			t.Fatal("RAR4 page content changed", page, e)
		}
	}
	reads := s.reads
	if _, e := c.page(0); e != nil || s.reads != reads {
		t.Fatal("revisiting RAR4 page fetched source", e)
	}
}

type comicRARScanTransport func(*http.Request) (*http.Response, error)

func (f comicRARScanTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestComicRARScanKeepsBoundsAndCancellation(t *testing.T) {
	t.Run("request cap", func(t *testing.T) {
		f, _ := comicRAR4TestBook(comicMaxRemoteRARIndexReads + 1)
		s := comicRARTestSource(t, f)
		if _, e := comicIndex(s, "book.rar", ""); !errors.Is(e, errComicLimit) || s.reads != comicMaxRemoteRARIndexReads {
			t.Fatal("RAR scan lost request bound", e, s.reads)
		}
		if s.indexing || s.rarIndex || s.bytes > comicMaxRemoteIndexBytes {
			t.Fatal("failed index retained scan state or exceeded byte budget")
		}
	})
	t.Run("byte cap", func(t *testing.T) {
		f, _ := comicRAR4TestBook(173)
		s := comicRARTestSource(t, f)
		if _, e := s.ReadAt(make([]byte, 8), 0); e != nil {
			t.Fatal(e)
		}
		s.bytes = comicMaxRemoteIndexBytes - comicRARIndexWindow + 1
		reads := s.reads
		if _, e := comicIndex(s, "book.rar", ""); !errors.Is(e, errComicLimit) || s.reads != reads {
			t.Fatal("RAR scan bypassed unchanged byte budget", e, s.reads, s.bytes)
		}
	})
	for _, failure := range []string{"cancel", "busy"} {
		t.Run(failure, func(t *testing.T) {
			f, _ := comicRAR4TestBook(173)
			s := comicRARTestSource(t, f)
			ctx, cancel := context.WithCancel(s.ctx)
			defer cancel()
			s.ctx = ctx
			base := s.client.Transport
			calls := 0
			s.client.Transport = comicRARScanTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				if calls == 10 {
					if failure == "cancel" {
						cancel()
						return nil, context.Canceled
					}
					return &http.Response{StatusCode: http.StatusServiceUnavailable, Body: http.NoBody, Header: make(http.Header)}, nil
				}
				return base.RoundTrip(r)
			})
			_, e := comicIndex(s, "book.rar", "")
			want := errComicBusy
			if failure == "cancel" {
				want = context.Canceled
			}
			if !errors.Is(e, want) || calls != 10 || s.indexing || s.rarIndex {
				t.Fatal("RAR scan continued after cancellation or upstream busy", e, calls)
			}
		})
	}
}
