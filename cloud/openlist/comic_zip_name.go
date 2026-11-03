package cloudcore

import (
	"encoding/binary"
	"hash/crc32"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

// Info-ZIP's Unicode Path field supplements legacy filename bytes. Keep the
// original bytes for CRC validation and leave explicitly UTF-8 names alone.
// APPNOTE 4.6.9 requires version 1 and a matching CRC of the original name.
func comicZIPName(name string, flags uint16, extra []byte) string {
	if flags&0x800 != 0 {
		return name
	}
	for len(extra) >= 4 {
		tag := binary.LittleEndian.Uint16(extra)
		size := int(binary.LittleEndian.Uint16(extra[2:]))
		extra = extra[4:]
		if size > len(extra) {
			return name
		}
		field := extra[:size]
		extra = extra[size:]
		if tag == 0x7075 && len(field) > 5 && field[0] == 1 &&
			binary.LittleEndian.Uint32(field[1:5]) == crc32.ChecksumIEEE([]byte(name)) && utf8.Valid(field[5:]) {
			return string(field[5:])
		}
	}
	return name
}

// Legacy Windows ZIPs may have GBK names without a Unicode Path field. Apply
// this only after Unicode field selection: valid UTF-8 and marked UTF-8 names
// must never be reinterpreted. Reject lossy decoding, including replacement
// characters silently emitted by x/text, by checking an exact byte round trip.
func comicZIPLegacyName(name string, flags uint16) string {
	if flags&0x800 != 0 || utf8.ValidString(name) || len(name) > 4096 {
		return name
	}
	decoded, err := simplifiedchinese.GBK.NewDecoder().String(name)
	if err != nil || strings.ContainsRune(decoded, utf8.RuneError) {
		return name
	}
	encoded, err := simplifiedchinese.GBK.NewEncoder().String(decoded)
	if err != nil || encoded != name {
		return name
	}
	return decoded
}
