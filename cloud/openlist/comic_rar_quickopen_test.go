package cloudcore

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/nwaples/rardecode/v2"
)

func comicRARTestNumbers(v ...uint64) []byte {
	var b []byte
	for _, n := range v {
		b = binary.AppendUvarint(b, n)
	}
	return b
}

func comicRARTestCRCBlock(body []byte) []byte {
	b := binary.AppendUvarint(nil, uint64(len(body)))
	b = append(b, body...)
	return append(binary.LittleEndian.AppendUint32(nil, crc32.ChecksumIEEE(b)), b...)
}

func comicRARTestHeader(kind, flags, packed uint64, body, extra []byte) []byte {
	b := comicRARTestNumbers(kind, flags)
	if flags&1 != 0 {
		b = binary.AppendUvarint(b, uint64(len(extra)))
	}
	if flags&2 != 0 {
		b = binary.AppendUvarint(b, packed)
	}
	b = append(b, body...)
	b = append(b, extra...)
	return comicRARTestCRCBlock(b)
}

func comicRARTestRecord(off, back uint64, data []byte) []byte {
	b := comicRARTestNumbers(off, back, uint64(len(data)))
	return comicRARTestCRCBlock(append(b, data...))
}

type comicRARSparse struct {
	size   int64
	blocks []comicRange
}

func (f comicRARSparse) ReadAt(p []byte, off int64) (int, error) {
	if off < 0 || off >= f.size {
		return 0, io.EOF
	}
	n := min(int64(len(p)), f.size-off)
	clear(p[:n])
	for _, b := range f.blocks {
		start, end := max(off, b.start), min(off+n, b.start+int64(len(b.data)))
		if start < end {
			copy(p[start-off:end-off], b.data[start-b.start:end-b.start])
		}
	}
	if n < int64(len(p)) {
		return int(n), io.EOF
	}
	return int(n), nil
}

// 300 real-sized sparse image gaps (> 8 GiB), without allocating/downloading
// their payloads. QO has more than 512 records to cover the old block-cache cap.
func comicRARTestSparseBook() (comicRARSparse, []byte, int64, []comicRange) {
	payload := []byte("\x89PNG\r\n\x1a\n")
	main := func(offset uint64) []byte {
		locator := comicRARTestNumbers(1, 1)
		// Fixed nine-byte vint keeps main-header length stable before size is known.
		for i := 0; i < 8; i++ {
			locator = append(locator, byte(offset&127)|128)
			offset >>= 7
		}
		locator = append(locator, byte(offset))
		extra := binary.AppendUvarint(nil, uint64(len(locator)))
		extra = append(extra, locator...)
		return comicRARTestHeader(1, 1, 0, []byte{0}, extra)
	}
	head := append([]byte("Rar!\x1a\x07\x01\x00"), main(0)...)
	f := comicRARSparse{blocks: []comicRange{{0, head}}}
	pos := int64(len(head))
	var copies []comicRange
	for i := 0; i < 300; i++ {
		makeFile := func(prefix string) []byte {
			name := []byte(fmt.Sprintf("%s/%04d.png", prefix, i))
			body := comicRARTestNumbers(4, uint64(len(payload)), 32)
			body = binary.LittleEndian.AppendUint32(body, crc32.ChecksumIEEE(payload))
			body = append(body, comicRARTestNumbers(0, 0, uint64(len(name)))...)
			return comicRARTestHeader(2, 2, uint64(len(payload)), append(body, name...), nil)
		}
		original, cached := makeFile("real"), makeFile("page")
		f.blocks = append(f.blocks, comicRange{pos, append(original, payload...)})
		copies = append(copies, comicRange{pos, cached})
		pos += int64(len(original) + len(payload))
		// Unknown service-like data block must be seek-skipped by the RAR reader.
		gap := comicRARTestHeader(99, 2, 32<<20, nil, nil)
		f.blocks = append(f.blocks, comicRange{pos, gap})
		copies = append(copies, comicRange{pos, gap})
		pos += int64(len(gap)) + 32<<20
	}
	qo := pos
	var data []byte
	for _, b := range copies {
		data = append(data, comicRARTestRecord(0, uint64(qo-b.start), b.data)...)
	}
	body := comicRARTestNumbers(4, uint64(len(data)), 0)
	body = binary.LittleEndian.AppendUint32(body, crc32.ChecksumIEEE(data))
	body = append(body, comicRARTestNumbers(0, 0, 2)...)
	body = append(body, 'Q', 'O')
	quick := comicRARTestHeader(3, 2, uint64(len(data)), body, nil)
	quick = append(quick, data...)
	quick = append(quick, comicRARTestHeader(5, 0, 0, []byte{0}, nil)...)
	f.blocks = append(f.blocks, comicRange{qo, quick})
	f.blocks[0].data = append([]byte("Rar!\x1a\x07\x01\x00"), main(uint64(qo-8))...)
	f.size = qo + int64(len(quick))
	return f, payload, qo, copies
}

type comicRARFastLocalTransport struct{ source *comicSource }

func (r comicRARFastLocalTransport) RoundTrip(q *http.Request) (*http.Response, error) {
	res, e := http.DefaultTransport.RoundTrip(q)
	// This fixture never contacts a cloud. Exercise the production budget but
	// skip its 250 ms pacing so the 128-request baseline test stays fast.
	r.source.lastRead = time.Time{}
	return res, e
}

func comicRARTestSource(t *testing.T, f comicRARSparse) *comicSource {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "book.rar", time.Unix(1, 0), io.NewSectionReader(f, 0, f.size))
	}))
	t.Cleanup(server.Close)
	s, e := newComicSource(context.Background(), server.URL)
	if e != nil {
		t.Fatal(e)
	}
	s.remote, s.lastRead = true, time.Time{}
	s.client = &http.Client{Transport: comicRARFastLocalTransport{s}}
	return s
}

func TestComicRARQuickOpenAvoidsSparseHeaderScan(t *testing.T) {
	f, payload, _, copies := comicRARTestSparseBook()
	legacy := comicRARTestSource(t, f)
	legacy.indexing = true
	_, e := rardecode.List("book.rar", rardecode.FileSystem(comicFS{legacy}))
	if !errors.Is(e, errComicLimit) || legacy.reads != comicMaxRemoteIndexReads {
		t.Fatal("legacy remote limit was not reproduced", legacy.reads, e)
	}
	s := comicRARTestSource(t, f)
	c, e := comicIndex(s, "book.cbr", "")
	if e != nil {
		t.Fatal(e)
	}
	if f.size < 8<<30 || len(c.pages) != 300 || len(s.rarHeaders) != len(copies) || s.reads > 3 || s.bytes > 512<<10 {
		t.Fatal("QO did not replace scattered header requests", f.size, len(c.pages), len(s.rarHeaders), s.reads, s.bytes)
	}
	if c.pages[0].Name != "page/0000.png" {
		t.Fatal("QO header was shadowed by original cached bytes", c.pages[0].Name)
	}
	c.dir = t.TempDir()
	for _, page := range []int{299, 0, 150} {
		filename, e := c.page(page)
		if e != nil {
			t.Fatal(e)
		}
		b, e := os.ReadFile(filename)
		if e != nil || !bytes.Equal(b, payload) {
			t.Fatal("extraction disagreed with indexed header", page, e)
		}
	}
	reads := s.reads
	if _, e = c.page(0); e != nil || s.reads != reads {
		t.Fatal("revisited page contacted source", e)
	}
	t.Logf("size=%d pages=%d QO_records=%d ranges_including_3_pages=%d bytes=%d", f.size, len(c.pages), len(s.rarHeaders), s.reads, s.bytes)
}

func TestComicRARQuickOpenRejectsInvalidSparseCopies(t *testing.T) {
	valid := comicRARTestRecord(0, 20, []byte{1, 2, 3})
	badCRC := append([]byte(nil), valid...)
	badCRC[0] ^= 1
	for name, data := range map[string][]byte{
		"crc":           badCRC,
		"truncated":     valid[:len(valid)-1],
		"overflow":      append([]byte{0, 0, 0, 0}, bytes.Repeat([]byte{255}, 10)...),
		"outside":       comicRARTestRecord(0, 101, []byte{1}),
		"crosses QO":    comicRARTestRecord(0, 1, []byte{1, 2}),
		"unknown flags": comicRARTestRecord(1, 20, []byte{1}),
		"overlap":       append(append([]byte(nil), valid...), comicRARTestRecord(0, 19, []byte{1})...),
		"reversed":      append(append([]byte(nil), valid...), comicRARTestRecord(0, 30, []byte{1})...),
	} {
		t.Run(name, func(t *testing.T) {
			if _, ok := comicRARQuickOpenRanges(data, 100); ok {
				t.Fatal("invalid sparse cache accepted")
			}
		})
	}
	if blocks, ok := comicRARQuickOpenRanges(valid, 100); !ok || len(blocks) != 1 || blocks[0].start != 80 {
		t.Fatal("valid sparse cache rejected")
	}
}

func TestComicRARQuickOpenInvalidCacheKeepsRemoteBudget(t *testing.T) {
	f, _, qo, _ := comicRARTestSparseBook()
	for i := range f.blocks {
		if f.blocks[i].start == qo {
			h, ok := comicRARParseHeader(f.blocks[i].data)
			if !ok {
				t.Fatal("invalid test service")
			}
			f.blocks[i].data[h.size] ^= 1
		}
	}
	s := comicRARTestSource(t, f)
	if _, e := comicIndex(s, "book.rar", ""); !errors.Is(e, errComicLimit) || s.reads != comicMaxRemoteIndexReads || len(s.rarHeaders) != 0 {
		t.Fatal("invalid QO bypassed remote bounds", s.reads, e)
	}
}
