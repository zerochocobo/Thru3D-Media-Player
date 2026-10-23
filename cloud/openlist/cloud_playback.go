package cloudcore

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	cloudnet "github.com/OpenListTeam/OpenList/v4/internal/net"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/OpenListTeam/OpenList/v4/server/common"
	"github.com/gin-gonic/gin"
)

type cloudPlaybackReader interface {
	PlayerPlaybackTarget(context.Context, string, string) (model.Obj, error)
}

// A process-local capability binds the verified object, not a reusable path.
// Neither proxy requests nor Range seeks call op.Get or enumerate directories.
type cloudPlaybackLease struct {
	storage       driver.Driver
	mount, remote string
	file          model.Obj
	created       time.Time
	*cloudPlaybackLinks
}

// Separate byte readers for one verified file must share its UA-bound download
// ticket. Reissuing tickets per reader can invalidate an active reader's URL.
type cloudPlaybackLinks struct {
	mu    sync.Mutex
	links map[string]cloudPlaybackLink
}
type cloudPlaybackLink struct {
	url            string
	header         http.Header
	expires        time.Time
	archiveExpires time.Time
}

var cloudPlaybackLeases = struct {
	sync.Mutex
	items map[string]*cloudPlaybackLease
}{items: map[string]*cloudPlaybackLease{}}

func playbackLeaseURL(storage driver.Driver, mount, remote string, file model.Obj) (string, error) {
	return boundPlaybackLeaseURL(storage, mount, remote, file, false)
}

func boundPlaybackLeaseURL(storage driver.Driver, mount, remote string, file model.Obj, archive bool) (string, error) {
	if streamBase == "" || file == nil || file.IsDir() || (!archive && !cloudID.MatchString(file.GetID())) || file.GetSize() <= 0 {
		return "", errors.New("playback stream unavailable")
	}
	key := searchKey()
	if key == "" {
		return "", errors.New("playback stream unavailable")
	}
	now := time.Now()
	cloudPlaybackLeases.Lock()
	defer cloudPlaybackLeases.Unlock()
	var shared *cloudPlaybackLinks
	for id, lease := range cloudPlaybackLeases.items {
		if now.Sub(lease.created) >= 24*time.Hour {
			delete(cloudPlaybackLeases.items, id)
		} else if lease.storage == storage && lease.mount == mount && lease.remote == remote &&
			lease.file.GetID() == file.GetID() && lease.file.GetSize() == file.GetSize() && lease.file.GetName() == file.GetName() && lease.file.ModTime().Equal(file.ModTime()) {
			shared = lease.cloudPlaybackLinks
		}
	}
	if len(cloudPlaybackLeases.items) >= 256 {
		var oldest string
		for id, lease := range cloudPlaybackLeases.items {
			if oldest == "" || lease.created.Before(cloudPlaybackLeases.items[oldest].created) {
				oldest = id
			}
		}
		delete(cloudPlaybackLeases.items, oldest)
	}
	if shared == nil {
		shared = &cloudPlaybackLinks{links: map[string]cloudPlaybackLink{}}
	}
	cloudPlaybackLeases.items[key] = &cloudPlaybackLease{storage: storage, mount: mount, remote: remote, file: file, created: now, cloudPlaybackLinks: shared}
	u := url.URL{Path: "/" + file.GetName()}
	prefix := "-115/"
	if archive {
		prefix = "-archive/"
	}
	return streamBase + prefix + key + u.EscapedPath(), nil
}

func (lease *cloudPlaybackLease) link(ctx context.Context, header http.Header) (*model.Link, error) {
	lease.mu.Lock()
	defer lease.mu.Unlock()
	ua := header.Get("User-Agent")
	if cached, ok := lease.links[ua]; ok {
		expires := cached.expires
		if header.Get("X-Thru3D-Archive-Read") == "1" {
			expires = cached.archiveExpires
		}
		if time.Now().Before(expires) {
			return &model.Link{URL: cached.url, Header: cached.header.Clone()}, nil
		}
	}
	providerHeader := header.Clone()
	providerHeader.Del("X-Thru3D-Archive-Read")
	link, err := lease.storage.Link(ctx, lease.file, model.LinkArgs{Header: providerHeader})
	if err != nil {
		return nil, err
	}
	defer link.Close()
	if link.URL == "" || link.RangeReader != nil {
		return nil, errors.New("invalid native playback link")
	}
	upstream, err := url.Parse(link.URL)
	if err != nil || upstream.Scheme != "http" && upstream.Scheme != "https" || upstream.Host == "" {
		return nil, errors.New("invalid native playback origin")
	}
	expires := time.Now().Add(2 * time.Minute)
	// Archive ranges reuse the ticket for the driver's declared cache lifetime. When
	// none is supplied, an explicit auth denial invalidates it; the capability
	// itself remains bounded to 24 hours and its account/object identity.
	archiveExpires := time.Now().Add(24 * time.Hour)
	if link.Expiration != nil && *link.Expiration < 24*time.Hour {
		archiveExpires = time.Now().Add(*link.Expiration)
	}
	if link.Expiration != nil && *link.Expiration < 2*time.Minute {
		expires = time.Now().Add(*link.Expiration)
	}
	if len(lease.links) >= 4 {
		clear(lease.links)
	}
	lease.links[ua] = cloudPlaybackLink{url: link.URL, header: link.Header.Clone(), expires: expires, archiveExpires: archiveExpires}
	return &model.Link{URL: link.URL, Header: link.Header.Clone()}, nil
}

func playback115Proxy(c *gin.Context) {
	servePlayback115(c, op.GetStorageAndActualPath)
}

func (lease *cloudPlaybackLease) invalidate(header http.Header, failedURL string) {
	lease.mu.Lock()
	defer lease.mu.Unlock()
	ua := header.Get("User-Agent")
	if current, ok := lease.links[ua]; ok && current.url == failedURL {
		delete(lease.links, ua)
	}
}

func servePlayback115(c *gin.Context, resolve func(string) (driver.Driver, string, error)) {
	cloudPlaybackLeases.Lock()
	lease := cloudPlaybackLeases.items[c.Param("lease")]
	cloudPlaybackLeases.Unlock()
	if lease == nil || time.Since(lease.created) >= 24*time.Hour || c.Param("name") != "/"+lease.file.GetName() {
		c.Status(http.StatusNotFound)
		return
	}
	storage, actual, err := resolve(lease.mount + lease.remote)
	if err != nil || storage != lease.storage || actual != lease.remote || storage.GetStorage().Disabled {
		c.Status(http.StatusGone)
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
	archiveRead := c.Request.Header.Get("X-Thru3D-Archive-Read") == "1"
	link, err := lease.link(ctx, c.Request.Header)
	c.Request.Header.Del("X-Thru3D-Archive-Read") // Internal policy never goes to the provider.
	cancel()                                      // Only link lookup is bounded here; media may stream for hours.
	if err != nil {
		c.Status(http.StatusBadGateway)
		return
	}
	defer link.Close()
	selectedURL := link.URL
	if storage.GetStorage().ProxyRange && !archiveRead {
		link = common.ProxyRange(c, link, lease.file.GetSize())
	}
	writer := &common.WrittenResponseWriter{ResponseWriter: c.Writer}
	if err := common.Proxy(writer, c.Request, link, lease.file); err != nil && !writer.IsWritten() {
		// RequestHttp wraps every upstream HTTP error. Preserve its status so
		// the existing client can distinguish an expired link from a temporary
		// gateway failure; never expose the wrapped URL or response body.
		status := http.StatusBadGateway
		var upstream cloudnet.HttpStatusCodeError
		if errors.As(err, &upstream) && int(upstream) >= 400 && int(upstream) <= 599 {
			status = int(upstream)
		}
		reason, message := readDenial(err)
		if (status == http.StatusUnauthorized || status == http.StatusForbidden || status == http.StatusGone) && reason != "cdn_connections_limited" && reason != "cdn_rate_limited" {
			lease.invalidate(c.Request.Header, selectedURL)
		}
		recordReadDiagnostic(status, reason, message, link.Header.Get("User-Agent") == c.Request.Header.Get("User-Agent"))
		c.Header("X-Thru3D-Upstream-Reason", reason)
		c.Status(status)
	}
}

func playback115Routes(streams *gin.Engine, capability string) {
	// A separate prefix avoids Gin wildcard conflicts with legacy /cap/*path.
	base := "/" + strings.TrimPrefix(capability, "/") + "-115/:lease/*name"
	streams.GET(base, playback115Proxy)
	streams.HEAD(base, playback115Proxy)
	archive := "/" + strings.TrimPrefix(capability, "/") + "-archive/:lease/*name"
	streams.GET(archive, playback115Proxy)
	streams.HEAD(archive, playback115Proxy)
}
