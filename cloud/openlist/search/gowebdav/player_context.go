package gowebdav

import (
	"context"
	"net/http"
	"os"
)

// A request-local client keeps cancellation isolated from playback and other
// accounts while reusing the configured transport, cookies and DAV auth policy.
func (c *Client) PlayerReadDir(ctx context.Context, path string) ([]os.FileInfo, error) {
	c.authMutex.Lock()
	auth := c.auth
	view := NewClient(c.root, auth.User(), auth.Pass())
	if auth.Type() == "BasicAuth" {
		view.auth = &BasicAuth{auth.User(), auth.Pass()}
	}
	c.authMutex.Unlock()
	view.headers = c.headers.Clone()
	client := *c.c
	client.Transport = playerBoundedTransport{c.c.Transport}
	view.c = &client
	interceptor := c.interceptor
	view.interceptor = func(method string, r *http.Request) {
		*r = *r.WithContext(ctx)
		if interceptor != nil {
			interceptor(method, r)
		}
	}
	files, err := view.playerBoundedReadDir(path)
	if err == nil {
		view.authMutex.Lock()
		accepted := view.auth
		view.authMutex.Unlock()
		// Basic auth is immutable. Reuse its negotiated policy without sharing
		// request contexts or mutable digest nonce state between clients.
		if accepted.Type() == "BasicAuth" {
			c.authMutex.Lock()
			if c.auth.Type() == "NoAuth" {
				c.auth = &BasicAuth{accepted.User(), accepted.Pass()}
			}
			c.authMutex.Unlock()
		}
	}
	return files, err
}
