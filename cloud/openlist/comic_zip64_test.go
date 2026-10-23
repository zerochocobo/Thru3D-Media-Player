package cloudcore

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// Relocate a tiny real archive above 4 GiB and rebuild its central directory
// using selective ZIP64 extra values. No multi-gigabyte fixture is allocated.
func comicZIP64Sparse(t *testing.T, data []byte, fields int) comicRARSparse {
	t.Helper()
	const base = int64(5 << 30)
	end := bytes.LastIndex(data, []byte("PK\x05\x06"))
	if end < 0 || end+22 > len(data) {
		t.Fatal("fixture ZIP end record missing")
	}
	count := binary.LittleEndian.Uint16(data[end+10:])
	start := int(binary.LittleEndian.Uint32(data[end+16:]))
	var directory []byte
	pos := start
	for i := 0; i < int(count); i++ {
		h := append([]byte(nil), data[pos:pos+46]...)
		nameSize := int(binary.LittleEndian.Uint16(h[28:]))
		extraSize := int(binary.LittleEndian.Uint16(h[30:]))
		commentSize := int(binary.LittleEndian.Uint16(h[32:]))
		size := 46 + nameSize + extraSize + commentSize
		offset := base + int64(binary.LittleEndian.Uint32(h[42:]))
		var values []byte
		if fields&1 != 0 {
			values = binary.LittleEndian.AppendUint64(values, uint64(binary.LittleEndian.Uint32(h[24:])))
			binary.LittleEndian.PutUint32(h[24:], ^uint32(0))
		}
		if fields&2 != 0 {
			values = binary.LittleEndian.AppendUint64(values, uint64(binary.LittleEndian.Uint32(h[20:])))
			binary.LittleEndian.PutUint32(h[20:], ^uint32(0))
		}
		values = binary.LittleEndian.AppendUint64(values, uint64(offset))
		binary.LittleEndian.PutUint32(h[42:], ^uint32(0))
		if fields&4 != 0 {
			values = binary.LittleEndian.AppendUint32(values, 0)
			binary.LittleEndian.PutUint16(h[34:], ^uint16(0))
		}
		extra := binary.LittleEndian.AppendUint16(nil, 1)
		extra = binary.LittleEndian.AppendUint16(extra, uint16(len(values)))
		extra = append(extra, values...)
		binary.LittleEndian.PutUint16(h[30:], uint16(extraSize+len(extra)))
		binary.LittleEndian.PutUint16(h[6:], max(45, binary.LittleEndian.Uint16(h[6:])))
		directory = append(directory, h...)
		directory = append(directory, data[pos+46:pos+46+nameSize+extraSize]...)
		directory = append(directory, extra...)
		directory = append(directory, data[pos+46+nameSize+extraSize:pos+size]...)
		pos += size
	}
	cdOffset := base + int64(start)
	end64 := binary.LittleEndian.AppendUint32(nil, 0x06064b50)
	end64 = binary.LittleEndian.AppendUint64(end64, 44)
	end64 = binary.LittleEndian.AppendUint16(end64, 45)
	end64 = binary.LittleEndian.AppendUint16(end64, 45)
	end64 = binary.LittleEndian.AppendUint32(end64, 0)
	end64 = binary.LittleEndian.AppendUint32(end64, 0)
	end64 = binary.LittleEndian.AppendUint64(end64, uint64(count))
	end64 = binary.LittleEndian.AppendUint64(end64, uint64(count))
	end64 = binary.LittleEndian.AppendUint64(end64, uint64(len(directory)))
	end64 = binary.LittleEndian.AppendUint64(end64, uint64(cdOffset))
	locator := binary.LittleEndian.AppendUint32(nil, 0x07064b50)
	locator = binary.LittleEndian.AppendUint32(locator, 0)
	locator = binary.LittleEndian.AppendUint64(locator, uint64(cdOffset)+uint64(len(directory)))
	locator = binary.LittleEndian.AppendUint32(locator, 1)
	eocd := append([]byte(nil), data[end:end+22]...)
	binary.LittleEndian.PutUint32(eocd[12:], uint32(len(directory)))
	binary.LittleEndian.PutUint32(eocd[16:], ^uint32(0))
	binary.LittleEndian.PutUint16(eocd[20:], 0)
	tail := append(directory, end64...)
	tail = append(tail, locator...)
	tail = append(tail, eocd...)
	return comicRARSparse{size: cdOffset + int64(len(tail)), blocks: []comicRange{{base, data[:start]}, {cdOffset, tail}}}
}

func TestComicZIP64SelectiveFieldsAndEncryptedRandomPages(t *testing.T) {
	root := os.Getenv("COMIC_FIXTURES")
	if root == "" {
		t.Skip("Synthetic ZIP fixtures required")
	}
	for _, name := range []string{"plain.zip", "zipcrypto.zip", "aes.zip"} {
		for _, fields := range []int{0, 1, 2, 3, 7} {
			t.Run(name+"/fields_"+string(rune('0'+fields)), func(t *testing.T) {
				data, e := os.ReadFile(filepath.Join(root, name))
				if e != nil {
					t.Fatal(e)
				}
				s := comicRARTestSource(t, comicZIP64Sparse(t, data, fields))
				password := ""
				if name != "plain.zip" {
					password = "comic-test"
				}
				c, e := comicIndex(s, "large.cbz", password)
				if e != nil || len(c.pages) != 3 {
					t.Fatal("ZIP64 metadata failed", e)
				}
				c.dir = t.TempDir()
				for _, page := range []int{2, 0, 1} {
					p, e := c.page(page)
					if e != nil {
						t.Fatal("ZIP64 offset failed", page, e)
					}
					b, e := os.ReadFile(p)
					if e != nil || !bytes.HasPrefix(b, []byte("\x89PNG")) {
						t.Fatal("ZIP64 extracted bytes failed", page, e)
					}
				}
			})
		}
	}
}
