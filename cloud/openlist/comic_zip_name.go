package cloudcore

import (
	"encoding/binary"
	"hash/crc32"
	"unicode/utf8"
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
