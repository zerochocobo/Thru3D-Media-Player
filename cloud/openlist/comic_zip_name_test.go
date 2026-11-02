package cloudcore

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"hash/crc32"
	"os"
	"strings"
	"testing"

	zip "github.com/KirCute/zip"
)

func comicZIPTestUnicodePath(raw, name string) []byte {
	field := append([]byte{1}, binary.LittleEndian.AppendUint32(nil, crc32.ChecksumIEEE([]byte(raw)))...)
	field = append(field, name...)
	extra := binary.LittleEndian.AppendUint16(nil, 0x7075)
	extra = binary.LittleEndian.AppendUint16(extra, uint16(len(field)))
	return append(extra, field...)
}

func TestComicZIPUnicodeNameValidationAndExistingNames(t *testing.T) {
	raw := "\xd6\xd0\xce\xc4/1.png" // GBK: 中文/1.png
	valid := comicZIPTestUnicodePath(raw, "中文/1.png")
	badCRC := bytes.Clone(valid)
	badCRC[5] ^= 1
	badVersion := bytes.Clone(valid)
	badVersion[4] = 2
	for _, tc := range []struct {
		name, raw, want string
		flags           uint16
		extra           []byte
	}{
		{"English", "book/page.png", "book/page.png", 0, nil},
		{"UTF8 Chinese", "中文/图片.png", "中文/图片.png", 0x800, nil},
		{"UTF8 Japanese", "日本語/あ.png", "日本語/あ.png", 0x800, nil},
		{"UTF8 emoji", "相册/😀.png", "相册/😀.png", 0x800, nil},
		{"unmarked UTF8", "中文/图片.png", "中文/图片.png", 0, nil},
		{"legacy without extra unchanged", raw, raw, 0, nil},
		{"validated Unicode path", raw, "中文/1.png", 0, valid},
		{"ASCII fallback with Unicode path", "??/1.png", "中文/1.png", 0, comicZIPTestUnicodePath("??/1.png", "中文/1.png")},
		{"marked UTF8 wins", "中文/图片.png", "中文/图片.png", 0x800, comicZIPTestUnicodePath("中文/图片.png", "other.png")},
		{"unmarked UTF8 with matching extra", "中文/图片.png", "中文/图片.png", 0, comicZIPTestUnicodePath("中文/图片.png", "中文/图片.png")},
		{"bad CRC ignored", raw, raw, 0, badCRC},
		{"unknown version ignored", raw, raw, 0, badVersion},
		{"bad UTF8 ignored", raw, raw, 0, comicZIPTestUnicodePath(raw, "\xff.png")},
		{"empty Unicode path ignored", raw, raw, 0, comicZIPTestUnicodePath(raw, "")},
		{"short field ignored", raw, raw, 0, []byte{0x75, 0x70, 1, 0, 1}},
		{"truncated field ignored", raw, raw, 0, valid[:len(valid)-1]},
		{"truncated header ignored", raw, raw, 0, valid[:3]},
		{"unrelated field skipped", raw, "中文/1.png", 0, append([]byte{0xfe, 0xca, 1, 0, 0}, valid...)},
		{"bad field followed by valid field", raw, "中文/1.png", 0, append(bytes.Clone(badCRC), valid...)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := comicZIPName(tc.raw, tc.flags, tc.extra); got != tc.want {
				t.Fatalf("name changed incorrectly: got %q want %q", got, tc.want)
			}
		})
	}
}

func TestComicZIPUnicodeDirectoriesExtractionAndZIP64(t *testing.T) {
	for _, encryption := range []zip.EncryptionMethod{0, zip.StandardEncryption, zip.AES256Encryption} {
		var archive bytes.Buffer
		writer := zip.NewWriter(&archive)
		names := []struct {
			raw, decoded string
			flags        uint16
		}{
			{"\xd6\xd0\xce\xc4/", "中文/", 0},
			{"\xd6\xd0\xce\xc4/10.png", "中文/10.png", 0},
			{"\xd6\xd0\xce\xc4/2.png", "中文/2.png", 0},
			{"\xd6\xd0\xce\xc4/1.png", "中文/1.png", 0},
			{"正常中文/图片.png", "正常中文/图片.png", 0x800},
			{"日本語/あ.png", "日本語/あ.png", 0x800},
			{"unmarked中文.png", "unmarked中文.png", 0},
			{"English.png", "English.png", 0},
		}
		password := ""
		if encryption != 0 {
			password = "unicode-test"
		}
		for _, name := range names {
			header := &zip.FileHeader{Name: name.raw, Flags: name.flags, Method: zip.Deflate}
			if name.raw != name.decoded {
				header.Extra = comicZIPTestUnicodePath(name.raw, name.decoded)
			}
			if password != "" && !strings.HasSuffix(name.raw, "/") {
				header.SetPassword(password)
				header.SetEncryptionMethod(encryption)
			}
			file, err := writer.CreateHeader(header)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.HasSuffix(name.raw, "/") {
				if _, err = file.Write([]byte(name.decoded)); err != nil {
					t.Fatal(err)
				}
			}
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		for _, zip64 := range []bool{false, true} {
			sparse := comicRARSparse{size: int64(archive.Len()), blocks: []comicRange{{0, archive.Bytes()}}}
			if zip64 {
				sparse = comicZIP64Sparse(t, archive.Bytes(), 7)
			}
			source := comicRARTestSource(t, sparse)
			session, err := comicIndex(source, "names.cbz", password)
			if err != nil {
				t.Fatalf("index encryption=%d ZIP64=%v: %v", encryption, zip64, err)
			}
			encoded, err := json.Marshal(session.listing("names"))
			if err != nil {
				t.Fatal(err)
			}
			var entries []map[string]any
			if err = json.Unmarshal(encoded, &entries); err != nil || len(entries) != len(names) {
				t.Fatal("lost entries in JSON", err)
			}
			for i, name := range names {
				want := strings.TrimSuffix(name.decoded, "/")
				if entries[i]["title"] != want || entries[i]["path"] != want {
					t.Fatalf("name lost in JSON encryption=%d ZIP64=%v: %v", encryption, zip64, entries[i])
				}
			}
			var numbered []string
			session.dir = t.TempDir()
			for i, page := range session.pages {
				if strings.HasPrefix(page.Name, "中文/") {
					numbered = append(numbered, page.Name)
				}
				file, err := session.page(i)
				if err != nil {
					t.Fatalf("extraction encryption=%d ZIP64=%v: %v", encryption, zip64, err)
				}
				data, err := os.ReadFile(file)
				if err != nil || string(data) != page.Name {
					t.Fatal("name correction changed selected image data", err)
				}
			}
			if strings.Join(numbered, ",") != "中文/1.png,中文/2.png,中文/10.png" {
				t.Fatal("natural page order changed", numbered)
			}
		}
	}
}

func TestComicZIPUnicodePathRetainsSafetyChecks(t *testing.T) {
	for _, name := range []string{"../1.png", "/1.png", "folder/../1.png", "folder\\1.png", "folder/\x001.png", strings.Repeat("字", 1400) + ".png"} {
		var archive bytes.Buffer
		writer := zip.NewWriter(&archive)
		if _, err := writer.CreateHeader(&zip.FileHeader{Name: "safe.png", Extra: comicZIPTestUnicodePath("safe.png", name)}); err != nil {
			t.Fatal(err)
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		source := comicRARTestSource(t, comicRARSparse{size: int64(archive.Len()), blocks: []comicRange{{0, archive.Bytes()}}})
		if _, err := comicIndex(source, "unsafe.zip", ""); !errors.Is(err, errComicDamaged) {
			t.Fatalf("unsafe Unicode path accepted: %q: %v", name, err)
		}
	}
}
