package cloudcore

// Comic sessions keep one index and one range source. No provider archive API or
// remote extraction is used. Management is JNI-only, like the other core routes.
import (
	"compress/flate"
	"context"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	zip "github.com/KirCute/zip"
	"github.com/bodgit/sevenzip"
	"github.com/gin-gonic/gin"
	"github.com/nwaples/rardecode/v2"
)

const comicMaxPage = 128 << 20
const comicMaxEntries = 20000
const comicMaxRemoteIndexReads = 128
const comicMaxRemoteIndexBytes = 16 << 20

// RAR4 and RAR5 without usable Quick Open copies need one request per scattered
// header. Use small reads and allow ordinary books, while bounding a scan to
// roughly two minutes of pacing (plus network time), rather than unbounded I/O.
const comicMaxRemoteRARIndexReads = 512
const comicRARIndexWindow = 4 << 10

var errComicUnsupported = errors.New("Archive format or compression is not supported")
var errComicSolid = errors.New("Solid archives are not supported")
var errComicPassword = errors.New("Archive password required or incorrect")
var errComicLimit = errors.New("Archive exceeds reading limits")
var errComicDamaged = errors.New("Archive is damaged or could not be verified")
var errComicRange = errors.New("Source does not support archive range reading")
var errComicBusy = errors.New("Archive source is busy; try again later")

type comicRange struct {
	start int64
	data  []byte
}
type comicSource struct {
	ctx        context.Context
	url        string
	size       int64
	client     *http.Client
	blocks     []comicRange
	bytes      int64
	reads      int
	etag       string
	modified   string
	remote     bool
	lastRead   time.Time
	payload    comicRange
	pageRead   bool
	indexing   bool
	rarIndex   bool
	rarHeaders []comicRange
}

func newComicSource(ctx context.Context, address string) (*comicSource, error) {
	u, e := url.Parse(address)
	if e != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.User != nil {
		return nil, errComicUnsupported
	}
	s := &comicSource{ctx: ctx, url: address, client: &http.Client{Timeout: 2 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	// Probe with a real range; HEAD and Accept-Ranges are not evidence of seeking.
	req, _ := http.NewRequestWithContext(ctx, "GET", address, nil)
	req.Header.Set("Range", "bytes=0-0")
	res, e := s.client.Do(req)
	if e != nil {
		return nil, e
	}
	defer res.Body.Close()
	var start, end int64
	if res.StatusCode != 206 {
		if res.StatusCode == 429 || res.StatusCode == 503 {
			return nil, errComicBusy
		}
		return nil, errComicRange
	}
	if _, e = fmt.Sscanf(res.Header.Get("Content-Range"), "bytes %d-%d/%d", &start, &end, &s.size); e != nil || start != 0 || end != 0 || s.size < 8 {
		return nil, errComicDamaged
	}
	s.etag = res.Header.Get("ETag")
	s.modified = res.Header.Get("Last-Modified")
	s.lastRead = time.Now()
	return s, nil
}
func (s *comicSource) fetch(off, n int64) ([]byte, error) {
	if e := s.ctx.Err(); e != nil {
		return nil, e
	}
	if off < 0 || n < 0 || off > s.size || n > s.size-off || n > comicMaxPage+256*1024 {
		return nil, errComicLimit
	}
	indexReads := comicMaxRemoteIndexReads
	if s.rarIndex {
		indexReads = comicMaxRemoteRARIndexReads
	}
	if s.remote && s.indexing && (s.reads >= indexReads || n > comicMaxRemoteIndexBytes-s.bytes) {
		return nil, errComicLimit
	}
	s.reads++
	s.bytes += n
	if s.reads > 4096 || s.bytes > 256<<20 {
		return nil, errComicLimit
	}
	if s.remote {
		delay := time.Until(s.lastRead.Add(250 * time.Millisecond))
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-s.ctx.Done():
				return nil, s.ctx.Err()
			}
		}
	}
	s.lastRead = time.Now()
	req, _ := http.NewRequestWithContext(s.ctx, "GET", s.url, nil)
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", off, off+n-1))
	req.Header.Set("Accept-Encoding", "identity")
	if s.etag != "" {
		req.Header.Set("If-Range", s.etag)
	} else if s.modified != "" {
		req.Header.Set("If-Range", s.modified)
	}
	res, e := s.client.Do(req)
	if e != nil {
		return nil, e
	}
	defer res.Body.Close()
	if res.StatusCode == 429 || res.StatusCode == 503 {
		return nil, errComicBusy
	}
	var start, end, total int64
	if res.StatusCode != 206 {
		return nil, errComicRange
	}
	if _, e = fmt.Sscanf(res.Header.Get("Content-Range"), "bytes %d-%d/%d", &start, &end, &total); e != nil || start != off || end != off+n-1 || total != s.size {
		return nil, errComicDamaged
	}
	if s.etag != "" && res.Header.Get("ETag") != "" && res.Header.Get("ETag") != s.etag {
		return nil, errComicDamaged
	}
	b, e := io.ReadAll(io.LimitReader(res.Body, n+1))
	if e != nil {
		return nil, e
	}
	if int64(len(b)) != n {
		return nil, errComicDamaged
	}
	return b, nil
}

// cachedAt can span a previous partial page while prime builds its replacement.
func (s *comicSource) cachedAt(off int64, extra ...comicRange) []byte {
	var found []byte
	take := func(b comicRange) {
		if off >= b.start && off < b.start+int64(len(b.data)) {
			data := b.data[off-b.start:]
			if len(data) > len(found) {
				found = data
			}
		}
	}
	take(s.payload)
	for _, block := range s.blocks {
		take(block)
	}
	for _, block := range extra {
		take(block)
	}
	return found
}
func (s *comicSource) gapEnd(off, end int64, extra ...comicRange) int64 {
	take := func(b comicRange) {
		if len(b.data) > 0 && b.start > off && b.start < end {
			end = b.start
		}
	}
	take(s.payload)
	for _, block := range s.blocks {
		take(block)
	}
	for _, block := range extra {
		take(block)
	}
	return end
}
func (s *comicSource) cacheBlock(off int64, data []byte) {
	if len(data) == 0 || len(data) > 2<<20 {
		return
	}
	kept := s.blocks[:0]
	used := len(data)
	for _, block := range s.blocks {
		if block.start >= off && block.start+int64(len(block.data)) <= off+int64(len(data)) {
			continue
		}
		kept = append(kept, block)
		used += len(block.data)
	}
	clear(s.blocks[len(kept):])
	for len(kept) > 0 && (used > 16<<20 || len(kept) >= 512) {
		used -= len(kept[0].data)
		kept[0] = comicRange{}
		kept = kept[1:]
	}
	s.blocks = append(kept, comicRange{off, data})
}
func (s *comicSource) ReadAt(p []byte, off int64) (int, error) {
	if e := s.ctx.Err(); e != nil {
		return 0, e
	}
	if len(p) == 0 {
		return 0, nil
	}
	if off < 0 || off >= s.size {
		return 0, io.EOF
	}
	read := 0
	for read < len(p) && off < s.size {
		if e := s.ctx.Err(); e != nil {
			return read, e
		}
		data := s.cachedAt(off)
		if len(data) == 0 {
			window := int64(128 << 10)
			if s.indexing && s.rarIndex {
				// Decoder buffers are 4 KiB. Large read-ahead at every header
				// downloads image data that listing immediately seeks over.
				window = comicRARIndexWindow
			} else if s.pageRead {
				window = 1 << 20
			}
			end := min(s.size, off+max(int64(len(p)-read), window))
			end = s.gapEnd(off, end)
			var e error
			data, e = s.fetch(off, end-off)
			if e != nil {
				return read, e
			}
			s.cacheBlock(off, data)
		}
		n := copy(p[read:], data)
		read += n
		off += int64(n)
	}
	if read < len(p) {
		return read, io.EOF
	}
	return read, nil
}
func (s *comicSource) prime(off, n int64) error {
	if off < 0 || n <= 0 || off > s.size || n > s.size-off || n > comicMaxPage {
		return errComicLimit
	}
	if data := s.cachedAt(off); int64(len(data)) >= n {
		return nil
	}
	previous := s.payload
	data := make([]byte, n)
	if n > 128<<10 {
		s.payload = comicRange{off, data[:0]}
	}
	filled := int64(0)
	for filled < n {
		if e := s.ctx.Err(); e != nil {
			return e
		}
		chunk := s.cachedAt(off+filled, previous)
		if len(chunk) == 0 {
			// Completed chunks survive a cancelled large-page request. A later
			// request for that page resumes at the first unverified byte range.
			end := s.gapEnd(off+filled, min(off+n, off+filled+(4<<20)), previous)
			var e error
			chunk, e = s.fetch(off+filled, end-off-filled)
			if e != nil {
				return e
			}
		}
		filled += int64(copy(data[filled:], chunk))
		if n > 128<<10 {
			s.payload = comicRange{off, data[:filled]}
		}
	}
	if n <= 128<<10 {
		s.cacheBlock(off, data)
	}
	return nil
}

type comicPage struct {
	Name      string `json:"title"`
	Size      int64  `json:"size"`
	open      func() (io.ReadCloser, error)
	prime     func() error
	verify    func([]byte) bool
	encrypted bool
}
type comicSession struct {
	source      *comicSource
	pages       []comicPage
	entries     []comicEntry
	verifyFirst bool // 7Z does not expose per-file encryption metadata.
	dir         string
	cached      map[int]string
	recent      []int
}

type comicEntry struct {
	Name string
	Size int64
	Kind string
}

func (c *comicSession) listing(id string) []gin.H {
	pages := map[string]int{}
	for i, p := range c.pages {
		pages[p.Name] = i
	}
	entries := []gin.H{}
	for _, p := range c.entries {
		entry := gin.H{"title": p.Name, "path": p.Name, "kind": p.Kind, "size": p.Size}
		if i, ok := pages[p.Name]; ok && p.Kind == "image" {
			entry["uri"] = "comic://" + id + "/" + strconv.Itoa(i)
		}
		entries = append(entries, entry)
	}
	return entries
}

var comicSessions = map[string]*comicSession{}
var comicRequestMu = make(chan struct{}, 1)
var comicPending *comicSource

func comicImage(name string) bool {
	switch strings.ToLower(path.Ext(name)) {
	case ".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".tif", ".tiff", ".hdr", ".rgbe", ".exr":
		return true
	}
	return false
}
func comicName(name string) bool {
	return name != "" && len(name) <= 4096 && !strings.ContainsAny(name, "\x00\\") && !strings.HasPrefix(name, "/") && !strings.Contains("/"+name+"/", "/../")
}
func comicNatural(a, b string) bool {
	a = strings.ToLower(a)
	b = strings.ToLower(b)
	for len(a) > 0 && len(b) > 0 {
		if a[0] >= '0' && a[0] <= '9' && b[0] >= '0' && b[0] <= '9' {
			i, j := 0, 0
			for i < len(a) && a[i] >= '0' && a[i] <= '9' {
				i++
			}
			for j < len(b) && b[j] >= '0' && b[j] <= '9' {
				j++
			}
			x, y := strings.TrimLeft(a[:i], "0"), strings.TrimLeft(b[:j], "0")
			if len(x) != len(y) {
				return len(x) < len(y)
			}
			if x != y {
				return x < y
			}
			a = a[i:]
			b = b[j:]
			continue
		}
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		a = a[1:]
		b = b[1:]
	}
	return len(a) < len(b)
}

func comicIndex(s *comicSource, name, password string) (*comicSession, error) {
	s.indexing = true
	defer func() { s.indexing, s.rarIndex = false, false }()
	c := &comicSession{source: s, cached: map[int]string{}}
	addEntry := func(name string, size int64, directory bool) error {
		if directory {
			name = strings.TrimSuffix(name, "/")
		}
		if !comicName(name) {
			return errComicDamaged
		}
		kind := "file"
		if directory {
			kind = "folder"
		} else if comicImage(name) {
			kind = "image"
		}
		c.entries = append(c.entries, comicEntry{name, size, kind})
		return nil
	}
	add := func(name string, size int64, open func() (io.ReadCloser, error), prime func() error) error {
		if e := addEntry(name, size, false); e != nil {
			return e
		}
		if !comicImage(name) {
			return nil
		}
		if size <= 0 || size > comicMaxPage {
			return errComicLimit
		}
		c.pages = append(c.pages, comicPage{Name: name, Size: size, open: open, prime: prime})
		if len(c.pages) > comicMaxEntries {
			return errComicLimit
		}
		return nil
	}
	switch strings.ToLower(path.Ext(name)) {
	case ".zip", ".cbz":
		if e := s.prime(max(0, s.size-(128<<10)), min(s.size, 128<<10)); e != nil {
			return nil, e
		}
		r, e := zip.NewReader(s, s.size)
		if e != nil {
			return nil, e
		}
		if len(r.File) > comicMaxEntries {
			return nil, errComicLimit
		}
		for _, f := range r.File {
			if f.FileInfo().IsDir() {
				if e = addEntry(f.Name, 0, true); e != nil {
					return nil, e
				}
				continue
			}
			if comicImage(f.Name) && f.Method != 0 && f.Method != 8 {
				return nil, errComicUnsupported
			}
			if f.IsEncrypted() {
				f.SetPassword(password)
			}
			if comicImage(f.Name) && f.CompressedSize64 > comicMaxPage {
				return nil, errComicLimit
			}
			file := f
			if e = add(f.Name, int64(f.UncompressedSize64), file.Open, func() error {
				offset, e := file.DataOffset()
				if e != nil {
					return e
				}
				return s.prime(offset, int64(file.CompressedSize64))
			}); e != nil {
				return nil, e
			}
			if comicImage(f.Name) {
				c.pages[len(c.pages)-1].encrypted = f.IsEncrypted()
			}
		}
	case ".7z":
		c.verifyFirst = true
		r, e := sevenzip.NewReaderWithPassword(s, s.size, password)
		if e != nil {
			return nil, e
		}
		if len(r.File) > comicMaxEntries {
			return nil, errComicLimit
		}
		streams := map[int]bool{}
		for _, f := range r.File {
			if f.FileInfo().IsDir() {
				if e = addEntry(f.Name, 0, true); e != nil {
					return nil, e
				}
				continue
			}
			if f.UncompressedSize == 0 {
				if e = addEntry(f.Name, 0, false); e != nil {
					return nil, e
				}
				continue
			}
			if streams[f.Stream] {
				return nil, errComicSolid
			}
			streams[f.Stream] = true
			file := f
			if e = add(f.Name, int64(f.UncompressedSize), file.Open, nil); e != nil {
				return nil, e
			}
			if comicImage(f.Name) {
				// sevenzip exposes the file CRC but File.Open does not validate it.
				c.pages[len(c.pages)-1].verify = func(data []byte) bool { return crc32.ChecksumIEEE(data) == file.CRC32 }
			}
		}
	case ".rar", ".cbr":
		if e := comicPrepareRARQuickOpen(s); e != nil {
			return nil, e
		}
		// QO loading keeps its contiguous reads; only subsequent scattered
		// header misses use the smaller scan window and RAR request budget.
		s.rarIndex = true
		opts := []rardecode.Option{rardecode.FileSystem(comicFS{s}), rardecode.MaxDictionarySize(64 << 20)}
		if password != "" {
			opts = append(opts, rardecode.Password(password))
		}
		files, e := rardecode.List("book.rar", opts...)
		if e != nil {
			return nil, e
		}
		if len(files) > comicMaxEntries {
			return nil, errComicLimit
		}
		for _, f := range files {
			if f.Solid {
				return nil, errComicSolid
			}
			if f.IsDir {
				if e = addEntry(f.Name, 0, true); e != nil {
					return nil, e
				}
				continue
			}
			if f.LinkType != 0 || f.UnKnownSize {
				return nil, errComicUnsupported
			}
			file := f
			if e = add(f.Name, f.UnPackedSize, file.Open, nil); e != nil {
				return nil, e
			}
			if comicImage(f.Name) {
				c.pages[len(c.pages)-1].encrypted = f.Encrypted || f.HeaderEncrypted
			}
		}
	default:
		return nil, errComicUnsupported
	}
	sort.SliceStable(c.pages, func(i, j int) bool { return comicNatural(c.pages[i].Name, c.pages[j].Name) })
	return c, nil
}

// RAR's indexed File.Open reuses its recorded block locations. This FS forbids
// volume discovery and exposes seek, so listing skips payloads rather than downloading them.
type comicFS struct{ s *comicSource }

func (f comicFS) Open(name string) (fs.File, error) {
	if name != "book.rar" {
		return nil, errComicUnsupported
	}
	return &comicFile{SectionReader: io.NewSectionReader(f.s, 0, f.s.size), source: f.s}, nil
}

type comicFile struct {
	*io.SectionReader
	source *comicSource
}

// Return short reads at Quick Open cache boundaries. Filling the decoder's
// 4 KiB buffer across a cached header would otherwise fetch each image payload
// while merely listing. Use this same view for listing and File.Open, as RAR's
// format requires when Quick Open copies differ from the original headers.
func (f *comicFile) Read(p []byte) (int, error) {
	if e := f.source.ctx.Err(); e != nil {
		return 0, e
	}
	off, e := f.Seek(0, io.SeekCurrent)
	if e != nil {
		return 0, e
	}
	headers := f.source.rarHeaders
	i := sort.Search(len(headers), func(i int) bool { return headers[i].start > off })
	if i > 0 {
		h := headers[i-1]
		if off-h.start < int64(len(h.data)) {
			n := copy(p, h.data[off-h.start:])
			_, e = f.Seek(int64(n), io.SeekCurrent)
			return n, e
		}
	}
	if i < len(headers) && int64(len(p)) > headers[i].start-off {
		p = p[:headers[i].start-off]
	}
	return f.SectionReader.Read(p)
}

func (f *comicFile) Close() error               { return nil }
func (f *comicFile) Stat() (fs.FileInfo, error) { return comicStat{f.source.size}, nil }

type comicStat struct{ size int64 }

func (f comicStat) Name() string       { return "book.rar" }
func (f comicStat) Size() int64        { return f.size }
func (f comicStat) Mode() fs.FileMode  { return 0400 }
func (f comicStat) ModTime() time.Time { return time.Time{} }
func (f comicStat) IsDir() bool        { return false }
func (f comicStat) Sys() any           { return nil }

func (c *comicSession) page(index int) (result string, err error) {
	if index < 0 || index >= len(c.pages) {
		return "", errComicDamaged
	}
	if p := c.cached[index]; p != "" {
		c.touch(index)
		return p, nil
	}
	page := c.pages[index]
	defer func() {
		var corrupt flate.CorruptInputError
		if page.encrypted && (errors.Is(err, zip.ErrChecksum) || errors.Is(err, rardecode.ErrBadFileChecksum) || errors.As(err, &corrupt)) {
			err = errComicPassword
		}
	}()
	c.source.pageRead = page.prime == nil
	defer func() { c.source.pageRead = false }()
	if page.prime != nil {
		if e := page.prime(); e != nil {
			return "", e
		}
	}
	r, e := page.open()
	if e != nil {
		return "", e
	}
	defer r.Close()
	data, e := io.ReadAll(io.LimitReader(r, page.Size+1))
	if e != nil {
		return "", e
	}
	if int64(len(data)) != page.Size {
		return "", errComicDamaged
	}
	if page.verify != nil && !page.verify(data) {
		return "", errComicDamaged
	}
	// Read to EOF above: ZIP AES MAC/CRC and RAR checks must complete before publish.
	filename := filepath.Join(c.dir, strconv.Itoa(index)+strings.ToLower(path.Ext(page.Name)))
	if e = os.WriteFile(filename, data, 0600); e != nil {
		return "", e
	}
	c.cached[index] = filename
	c.touch(index)
	if len(c.recent) > 3 {
		old := c.recent[0]
		c.recent = c.recent[1:]
		os.Remove(c.cached[old])
		delete(c.cached, old)
	}
	return filename, nil
}
func (c *comicSession) touch(index int) {
	for i, old := range c.recent {
		if old == index {
			c.recent = append(c.recent[:i], c.recent[i+1:]...)
			break
		}
	}
	c.recent = append(c.recent, index)
}

// Transfer a verified extracted file to the reader's bounded window. A unique
// path keeps a retired, still-leased page safe when the same index is reopened.
func (c *comicSession) transferPath(ticket string) (string, error) {
	if len(ticket) != 32 || strings.Trim(ticket, "0123456789abcdef") != "" {
		return "", errComicDamaged
	}
	return filepath.Join(c.dir, "reading-"+ticket), nil
}
func (c *comicSession) takePage(index int, ticket string) (string, error) {
	target, err := c.transferPath(ticket)
	if err != nil {
		return "", err
	}
	name, err := c.page(index)
	if err != nil {
		return "", err
	}
	if err = os.Rename(name, target); err != nil {
		return "", err
	}
	delete(c.cached, index)
	// The reader now owns retention, including the initial password-check page.
	for old, file := range c.cached {
		os.Remove(file)
		delete(c.cached, old)
	}
	c.recent = nil
	return target, nil
}

func comicError(e error, password string) string {
	if e == nil {
		return ""
	}
	for _, known := range []error{errComicUnsupported, errComicSolid, errComicLimit, errComicDamaged, errComicRange, errComicBusy} {
		if errors.Is(e, known) {
			return known.Error()
		}
	}
	if errors.Is(e, zip.ErrPartCountMismatch) {
		return errComicUnsupported.Error()
	}
	if errors.Is(e, context.Canceled) || errors.Is(e, context.DeadlineExceeded) {
		return "Archive reading cancelled or timed out"
	}
	var se *sevenzip.ReadError
	if errors.Is(e, zip.ErrPassword) || errors.Is(e, rardecode.ErrArchiveEncrypted) || errors.Is(e, rardecode.ErrArchivedFileEncrypted) || strings.Contains(strings.ToLower(e.Error()), "password") || errors.As(e, &se) && se.Encrypted {
		return errComicPassword.Error()
	}
	if strings.HasPrefix(e.Error(), "Source does not support") || strings.HasPrefix(e.Error(), "Archive source is busy") || strings.HasPrefix(e.Error(), "Archive contains no") {
		return e.Error()
	}
	return errComicDamaged.Error()
}
func comicRoutes(api *gin.Engine) {
	api.POST("/comic", func(g *gin.Context) {
		var q struct {
			Op       string `json:"op"`
			Session  string `json:"session"`
			URL      string `json:"url"`
			Name     string `json:"name"`
			Password string `json:"password"`
			Cache    string `json:"cache"`
			Page     int    `json:"page"`
			Remote   bool   `json:"remote"`
			Transfer string `json:"transfer"`
		}
		if g.ShouldBindJSON(&q) != nil {
			g.JSON(200, gin.H{"code": 200, "data": gin.H{"error": errComicDamaged.Error()}})
			return
		}
		result := gin.H{}
		var e error
		switch q.Op {
		case "open":
			// The caller owns the sole foreground comic; replacement closes old secrets/files.
			for id, c := range comicSessions {
				os.RemoveAll(c.dir)
				delete(comicSessions, id)
			}
			var s *comicSource
			var c *comicSession
			if comicPending != nil && comicPending.url == q.URL {
				s = comicPending
				s.ctx = g.Request.Context()
				s.reads = 0
				s.bytes = 0
			} else {
				s, e = newComicSource(g.Request.Context(), q.URL)
			}
			comicPending = nil
			if e == nil {
				s.remote = q.Remote
				c, e = comicIndex(s, q.Name, q.Password)
			}
			if e == nil {
				if !filepath.IsAbs(q.Cache) {
					e = errComicUnsupported
				} else {
					e = os.MkdirAll(q.Cache, 0700)
				}
				if e == nil {
					c.dir, e = os.MkdirTemp(q.Cache, "comic-")
				}
				if e == nil {
					for i, page := range c.pages {
						if page.encrypted {
							_, e = c.page(i)
							break
						}
					}
				}
				if e == nil && c.verifyFirst && len(c.pages) > 0 {
					_, e = c.page(0)
				} // A password becomes reusable only after full verification.
				if e != nil && c.dir != "" {
					os.RemoveAll(c.dir)
				}
			}
			if e == nil {
				id := searchKey()
				comicSessions[id] = c
				result = gin.H{"session": id, "entries": c.listing(id), "verified": true}
			}
			if e != nil && comicError(e, q.Password) == errComicPassword.Error() {
				comicPending = s
			}
		case "page", "take-page":
			c := comicSessions[q.Session]
			if c == nil {
				e = errComicDamaged
			} else {
				c.source.ctx = g.Request.Context()
				c.source.reads = 0
				c.source.bytes = 0
				var p string
				if q.Op == "take-page" {
					p, e = c.takePage(q.Page, q.Transfer)
				} else {
					p, e = c.page(q.Page)
				}
				if e == nil {
					result["path"] = p
				}
			}
		case "discard-page":
			// Runs under comicRequestMu after even a cancelled take-page request.
			if c := comicSessions[q.Session]; c != nil {
				var target string
				target, e = c.transferPath(q.Transfer)
				if e == nil {
					os.Remove(target)
				}
			}
		case "close":
			comicPending = nil
			for id, c := range comicSessions {
				if q.Session == "" || id == q.Session {
					os.RemoveAll(c.dir)
					delete(comicSessions, id)
				}
			}
		default:
			e = errComicUnsupported
		}
		if e != nil {
			result = gin.H{"error": comicError(e, q.Password)}
		}
		g.JSON(200, gin.H{"code": 200, "data": result})
	})
}

var _ io.ReaderAt = (*comicSource)(nil)
