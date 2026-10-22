package gowebdav

import (
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	pathpkg "path"
)

type playerBoundedTransport struct{ base http.RoundTripper }

func (t playerBoundedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	base := t.base
	if base == nil {
		base = http.DefaultTransport
	}
	response, err := base.RoundTrip(req)
	if err == nil && req.Method == "PROPFIND" {
		response.Body = &playerBoundedBody{response.Body, 16 * 1024 * 1024}
	}
	return response, err
}

type playerBoundedBody struct {
	io.ReadCloser
	remaining int64
}

func (b *playerBoundedBody) Read(p []byte) (int, error) {
	if b.remaining <= 0 {
		return 0, errors.New("WebDAV directory metadata limit exceeded")
	}
	if int64(len(p)) > b.remaining {
		p = p[:b.remaining]
	}
	n, err := b.ReadCloser.Read(p)
	b.remaining -= int64(n)
	return n, err
}

// Same property parsing as upstream ReadDir; stop before allocating an unbounded listing.
func (c *Client) playerBoundedReadDir(path string) ([]os.FileInfo, error) {
	path = FixSlashes(path)
	files := make([]os.FileInfo, 0)
	skipSelf := true
	parse := func(resp interface{}) error {
		r := resp.(*response)

		if skipSelf {
			skipSelf = false
			if p := getProps(r, "200"); p != nil && p.Type.Local == "collection" {
				r.Props = nil
				return nil
			}
			return newPathError("ReadDir", path, 405)
		}

		if p := getProps(r, "200"); p != nil {
			f := new(File)
			if ps, err := url.PathUnescape(r.Href); err == nil {
				f.name = pathpkg.Base(ps)
			} else {
				f.name = p.Name
			}
			f.path = path + f.name
			f.modified = parseModified(&p.Modified)
			f.etag = p.ETag
			f.contentType = p.ContentType

			if p.Type.Local == "collection" {
				f.path += "/"
				f.size = 0
				f.isdir = true
			} else {
				f.size = parseInt64(&p.Size)
				f.isdir = false
			}

			if len(files) >= 20000 {
				return errors.New("WebDAV directory metadata limit exceeded")
			}
			files = append(files, *f)
		}

		r.Props = nil
		return nil
	}

	err := c.propfind(path, false,
		`<d:propfind xmlns:d='DAV:'>
			<d:prop>
				<d:displayname/>
				<d:resourcetype/>
				<d:getcontentlength/>
				<d:getcontenttype/>
				<d:getetag/>
				<d:getlastmodified/>
			</d:prop>
		</d:propfind>`,
		&response{},
		parse)

	if err != nil {
		if _, ok := err.(*os.PathError); !ok {
			err = newPathErrorErr("ReadDir", path, err)
		}
	}
	return files, err
}
