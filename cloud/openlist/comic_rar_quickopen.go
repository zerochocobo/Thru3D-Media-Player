package cloudcore

// RAR5's optional Quick Open service stores sparse copies of file headers in
// one contiguous region. Loading it avoids thousands of scattered CDN requests
// on large non-solid comics. Layout: https://www.rarlab.com/technote.htm
// Keep the normal request/byte caps for missing, partial or unusable indexes.
import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"io"
)

const comicMaxRARQuickOpenBytes = 8 << 20
const comicMaxRARHeader = 2 << 20

type comicRARCursor struct {
	b   []byte
	bad bool
}

func (c *comicRARCursor) number() uint64 {
	v, n := binary.Uvarint(c.b)
	if n <= 0 {
		c.bad = true
		c.b = nil
		return 0
	}
	c.b = c.b[n:]
	return v
}

func (c *comicRARCursor) take(n uint64) []byte {
	if n > uint64(len(c.b)) {
		c.bad = true
		c.b = nil
		return nil
	}
	b := c.b[:n]
	c.b = c.b[n:]
	return b
}

type comicRARHeader struct {
	kind, flags uint64
	packed      uint64
	body, extra []byte
	size        int
}

func comicRARParseHeader(b []byte) (h comicRARHeader, ok bool) {
	if len(b) < 7 {
		return h, false
	}
	c := comicRARCursor{b: b[4:]}
	size := c.number()
	prefix := len(b) - len(c.b)
	if c.bad || prefix > 7 || size > comicMaxRARHeader || size > uint64(len(c.b)) {
		return h, false
	}
	h.size = prefix + int(size)
	if binary.LittleEndian.Uint32(b) != crc32.ChecksumIEEE(b[4:h.size]) {
		return h, false
	}
	c.b = c.take(size)
	h.kind, h.flags = c.number(), c.number()
	var extra uint64
	if h.flags&1 != 0 {
		extra = c.number()
	}
	if h.flags&2 != 0 {
		h.packed = c.number()
	}
	if c.bad || extra > uint64(len(c.b)) {
		return h, false
	}
	h.body = c.take(uint64(len(c.b)) - extra)
	h.extra = c.b
	return h, !c.bad
}

func comicRARReadHeader(s *comicSource, off int64) (comicRARHeader, bool, error) {
	var prefix [7]byte
	if _, e := s.ReadAt(prefix[:], off); e != nil {
		return comicRARHeader{}, false, e
	}
	size, n := binary.Uvarint(prefix[4:])
	if n <= 0 || size > comicMaxRARHeader || size > uint64(s.size-off-4-int64(n)) {
		return comicRARHeader{}, false, nil
	}
	b := make([]byte, 4+n+int(size))
	if _, e := s.ReadAt(b, off); e != nil {
		return comicRARHeader{}, false, e
	}
	h, ok := comicRARParseHeader(b)
	return h, ok, nil
}

func comicPrepareRARQuickOpen(s *comicSource) error {
	// Password retries reuse one source and its validated copies.
	if len(s.rarHeaders) != 0 {
		return nil
	}
	var signature [8]byte
	if _, e := s.ReadAt(signature[:], 0); e != nil {
		return e
	}
	if !bytes.Equal(signature[:], []byte("Rar!\x1a\x07\x01\x00")) {
		return nil // RAR4/SFX continue through the existing reader.
	}
	main, ok, e := comicRARReadHeader(s, 8)
	if e != nil || !ok || main.kind != 1 {
		return e // Encrypted headers continue through the password-aware reader.
	}
	var quickOffset uint64
	extra := comicRARCursor{b: main.extra}
	for len(extra.b) > 0 && !extra.bad {
		record := comicRARCursor{b: extra.take(extra.number())}
		if record.number() == 1 && record.number()&1 != 0 {
			quickOffset = record.number()
			if record.bad {
				return nil
			}
		}
	}
	if extra.bad || quickOffset == 0 || quickOffset > uint64(s.size-8-7) {
		return nil
	}
	off := int64(quickOffset) + 8
	h, ok, e := comicRARReadHeader(s, off)
	if e != nil || !ok || h.kind != 3 || h.packed == 0 || h.packed > comicMaxRARQuickOpenBytes || h.packed > uint64(s.size-off-int64(h.size)) {
		return e
	}
	// Only uncompressed, unencrypted QO services are usable by this cache.
	c := comicRARCursor{b: h.body}
	flags := c.number()
	unpacked := c.number()
	c.number() // attributes
	if flags&2 != 0 {
		c.take(4)
	}
	var checksum []byte
	if flags&4 != 0 {
		checksum = c.take(4)
	}
	compression := c.number()
	c.number() // host OS
	name := c.take(c.number())
	if c.bad || compression != 0 || unpacked != h.packed || !bytes.Equal(name, []byte("QO")) || flags&9 != 0 {
		return nil
	}
	extra = comicRARCursor{b: h.extra}
	for len(extra.b) > 0 && !extra.bad {
		record := comicRARCursor{b: extra.take(extra.number())}
		if record.number() == 1 || record.bad {
			return nil
		}
	}
	if extra.bad {
		return nil
	}
	// Usually the end marker immediately follows QO. Include its tiny header
	// rather than spending another request just to finish the listing.
	data := make([]byte, int(min(h.packed+128, uint64(s.size-off-int64(h.size)))))
	if _, e := s.ReadAt(data, off+int64(h.size)); e != nil {
		return e
	}
	data = data[:h.packed]
	if checksum != nil && binary.LittleEndian.Uint32(checksum) != crc32.ChecksumIEEE(data) {
		return nil
	}
	headers, ok := comicRARQuickOpenRanges(data, off)
	if ok {
		s.rarHeaders = headers
	}
	return nil
}

func comicRARQuickOpenRanges(data []byte, off int64) ([]comicRange, bool) {
	var headers []comicRange
	var end int64
	for len(data) != 0 {
		if len(data) < 7 || len(headers) >= comicMaxEntries {
			return nil, false
		}
		c := comicRARCursor{b: data[4:]}
		size := c.number()
		prefix := len(data) - len(c.b)
		if c.bad || prefix > 7 || size > comicMaxRARHeader || size > uint64(len(c.b)) {
			return nil, false
		}
		length := prefix + int(size)
		if binary.LittleEndian.Uint32(data) != crc32.ChecksumIEEE(data[4:length]) {
			return nil, false
		}
		c.b = c.take(size)
		flags, back := c.number(), c.number()
		cached := c.take(c.number())
		if c.bad || flags != 0 || len(c.b) != 0 || len(cached) == 0 || back > uint64(off) || back < uint64(len(cached)) {
			return nil, false
		}
		start := off - int64(back)
		if start < end {
			return nil, false
		}
		headers = append(headers, comicRange{start, cached})
		end = start + int64(len(cached))
		data = data[length:]
	}
	return headers, len(headers) > 0
}

// Assert that the view still exposes seek so RAR skips payloads, never reads
// through the entire archive to reach the next header.
var _ io.ReadSeeker = (*comicFile)(nil)
