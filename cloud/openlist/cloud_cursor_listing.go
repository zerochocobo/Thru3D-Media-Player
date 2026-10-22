package cloudcore

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/webdav"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/gin-gonic/gin"
)

var errDirectoryPageExpired = errors.New("directory page expired; refresh the folder")

type cursorCloudDriver interface {
	PlayerFolder(context.Context, string, string) (model.Obj, error)
	PlayerPage(context.Context, model.Obj, string, string) ([]model.Obj, string, int64, error)
}

type cursorCloudPage struct {
	objects []model.Obj
	next    int
	total   int64
	expires time.Time
}
type cursorCloudSession struct {
	storage driver.Driver
	folder  model.Obj
	expires time.Time
	pages   map[int]cursorCloudPage
	cursors map[int]string
}

var cursorCloudSessions = map[string]*cursorCloudSession{} // Serialized JNI calls only.

func cursorListingRoutes(router *gin.Engine) { router.POST("/directory", cursorDirectory) }

func cursorDirectory(c *gin.Context) {
	var req struct {
		Mount    string `json:"mount"`
		Path     string `json:"path"`
		FolderID string `json:"folder_id"`
		Offset   int    `json:"offset"`
		PageSize int    `json:"page_size"`
		Order    string `json:"order"`
		Refresh  bool   `json:"refresh"`
	}
	if c.ShouldBindJSON(&req) != nil || req.Offset < 0 || req.Offset > 2147483647-1000 || req.PageSize < 0 || req.PageSize > 1000 || len(req.FolderID) > 2048 {
		cloudListError(c, "directory.request", errors.New("invalid directory page request"))
		return
	}
	pageSize := listingPageSize([]int{req.PageSize})
	if req.Offset%pageSize != 0 {
		cloudListError(c, "directory.request", errors.New("invalid directory offset"))
		return
	}
	storage, err := searchStorage(req.Mount, req.Path)
	if err != nil {
		cloudListError(c, "directory.storage", err)
		return
	}
	switch storage.Config().Name {
	case "BaiduNetdisk", "AliyundriveOpen", "QuarkOpen", "Onedrive", "WebDav":
	default:
		cloudListError(c, "directory.driver", errors.New("native directory paging unavailable"))
		return
	}
	native, ok := storage.(cursorCloudDriver)
	if !ok {
		cloudListError(c, "directory.driver", errors.New("native directory paging unavailable"))
		return
	}
	if strings.HasPrefix(req.Order, "mixed_") && storage.Config().Name != "WebDav" {
		cloudListError(c, "directory.order", errors.New("directory grouping unavailable"))
		return
	}
	switch strings.TrimPrefix(req.Order, "mixed_") {
	case "source", "name_asc", "name_desc", "size_asc", "size_desc", "modified_asc", "modified_desc":
	default:
		cloudListError(c, "directory.order", errors.New("invalid directory sort order"))
		return
	}
	page, err := readCursorDirectory(c.Request.Context(), storage, native, req.Mount, req.Path, req.FolderID, req.Offset, req.Order, req.Refresh, pageSize)
	if err != nil {
		if errors.Is(err, errDirectoryPageExpired) || strings.HasPrefix(err.Error(), "directory page expired") {
			c.JSON(200, gin.H{"code": 500, "message": "Cloud request failed", "error_reason": "cloud_page_expired", "error_detail": "directory.page: refresh to restart paging"})
			return
		}
		if strings.Contains(err.Error(), "directory location expired") {
			c.JSON(200, gin.H{"code": 500, "message": "Cloud request failed", "error_reason": "cloud_location_expired", "error_detail": "directory.location: reopen the cloud account or refresh to start at its root"})
			return
		}
		cloudListError(c, "directory.list", err)
		return
	}
	items := make([]gin.H, 0, len(page.objects))
	for _, obj := range page.objects {
		items = append(items, gin.H{"name": obj.GetName(), "id": obj.GetID(), "is_dir": obj.IsDir(), "size": obj.GetSize(), "modified_ms": cloudModified(obj)})
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"content": items, "total": page.total, "next_offset": page.next, "folder_id": req.FolderID}})
}

func readCursorDirectory(ctx context.Context, storage driver.Driver, native cursorCloudDriver, mount, remote, folderID string, offset int, order string, refresh bool, requestedSize ...int) (cursorCloudPage, error) {
	pageSize := listingPageSize(requestedSize)
	if pageSize < 1 || pageSize > 1000 {
		return cursorCloudPage{}, errors.New("invalid directory page size")
	}
	direct, isDirect := native.(offsetCloudDriver)
	if err := ctx.Err(); err != nil {
		return cursorCloudPage{}, err
	}
	key := mount + remote + "\x00" + order
	if pageSize != 48 {
		key += "\x00" + strconv.Itoa(pageSize)
	}
	if folderID == "" {
		for k, s := range cursorCloudSessions {
			if strings.HasPrefix(k, mount+remote+"\x00") && s.storage == storage && time.Now().Before(s.expires) {
				folderID = s.folder.GetID()
				break
			}
		}
	}
	session := cursorCloudSessions[key]
	if session != nil && (session.storage != storage || time.Now().After(session.expires) || folderID != "" && session.folder.GetID() != folderID) {
		delete(cursorCloudSessions, key)
		session = nil
	}
	if session == nil {
		if offset != 0 && !isDirect {
			return cursorCloudPage{}, errDirectoryPageExpired
		}
		folder, err := native.PlayerFolder(ctx, remote, folderID)
		if err != nil {
			return cursorCloudPage{}, err
		}
		if folder == nil || !folder.IsDir() {
			return cursorCloudPage{}, errors.New("cloud folder not found")
		}
		if len(cursorCloudSessions) >= 8 {
			var oldest string
			var expiry time.Time
			for k, s := range cursorCloudSessions {
				if oldest == "" || s.expires.Before(expiry) {
					oldest, expiry = k, s.expires
				}
			}
			delete(cursorCloudSessions, oldest)
		}
		session = &cursorCloudSession{storage: storage, folder: folder, pages: map[int]cursorCloudPage{}, cursors: map[int]string{0: ""}}
		cursorCloudSessions[key] = session
	}
	if refresh {
		// Keep the current start cursor; discard following pages from the old view.
		for i := range session.pages {
			if i >= offset {
				delete(session.pages, i)
			}
		}
		for i := range session.cursors {
			if i > offset {
				delete(session.cursors, i)
			}
		}
		if resetter, ok := native.(interface{ PlayerForget(string) }); ok {
			resetter.PlayerForget(remote)
		}
	}
	session.expires = time.Now().Add(5 * time.Minute)
	cached, wasCached := session.pages[offset]
	if wasCached && time.Now().Before(cached.expires) {
		return cached, nil
	}
	cursor, ok := session.cursors[offset]
	if !ok && isDirect {
		cursor, ok = direct.PlayerOffsetCursor(offset), true
	}
	if !ok {
		return cursorCloudPage{}, errDirectoryPageExpired
	}
	var objects []model.Obj
	var next string
	var total int64
	var err error
	if sized, ok := native.(sizedCursorCloudDriver); ok {
		objects, next, total, err = sized.PlayerPageSized(ctx, session.folder, cursor, order, pageSize)
	} else if pageSize == 48 {
		objects, next, total, err = native.PlayerPage(ctx, session.folder, cursor, order)
	} else {
		return cursorCloudPage{}, errors.New("directory page size unavailable")
	}
	if err != nil {
		return cursorCloudPage{}, err
	}
	if len(objects) > pageSize || total < -1 || total > 2147483647 || len(next) > 16384 || next != "" && next == cursor {
		return cursorCloudPage{}, errors.New("invalid directory page or repeated cursor")
	}
	for previous, token := range session.cursors {
		if next != "" && previous <= offset && next == token {
			return cursorCloudPage{}, errors.New("directory cursor cycle")
		}
	}
	if err := checkListingMetadata(objects); err != nil {
		return cursorCloudPage{}, err
	}
	seen := map[string]bool{}
	for _, obj := range objects {
		id := obj.GetID()
		if id == "" {
			id = obj.GetPath()
		}
		if id == "" || seen[id] {
			return cursorCloudPage{}, errors.New("directory page contains missing or repeated object IDs")
		}
		seen[id] = true
	}
	result := cursorCloudPage{objects: objects, total: total, next: -1, expires: time.Now().Add(2 * time.Minute)}
	if next != "" {
		result.next = offset + pageSize
	}
	if err := ctx.Err(); err != nil {
		return cursorCloudPage{}, err
	}
	// A refetched batch can change its continuation even after its cached rows
	// were evicted. Later pages must follow the new cursor chain.
	for i := range session.pages {
		if i > offset {
			delete(session.pages, i)
		}
	}
	for i := range session.cursors {
		if i > offset {
			delete(session.cursors, i)
		}
	}
	if next != "" {
		session.cursors[result.next] = next
	}
	session.pages[offset] = result
	// Keep cursor 0 and a bounded window around the requested page. Never replay
	// all preceding network pages to reconstruct an evicted or expired cursor.
	trimCursorPages(session, offset)
	trimDirectoryRows()
	return result, nil
}

func trimCursorPages(session *cursorCloudSession, offset int) {
	keys := make([]int, 0, len(session.cursors))
	for k := range session.cursors {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := keys[i]-offset, keys[j]-offset
		if a < 0 {
			a = -a
		}
		if b < 0 {
			b = -b
		}
		return a < b
	})
	for _, k := range keys[min(len(keys), 64):] {
		if k != 0 {
			delete(session.cursors, k)
			delete(session.pages, k)
		}
	}
	if len(session.pages) > 16 {
		pageKeys := make([]int, 0, len(session.pages))
		for k := range session.pages {
			pageKeys = append(pageKeys, k)
		}
		sort.Slice(pageKeys, func(i, j int) bool {
			a, b := pageKeys[i]-offset, pageKeys[j]-offset
			if a < 0 {
				a = -a
			}
			if b < 0 {
				b = -b
			}
			return a < b
		})
		for _, k := range pageKeys[16:] {
			delete(session.pages, k)
		}
	}
}

func dropCursorStorage(id int) {
	// DAV snapshots may outlive an evicted directory session.
	webdav.PlayerDropStorage(uint(id))
	for key, session := range cursorCloudSessions {
		if uint(id) == session.storage.GetStorage().ID {
			if dropper, ok := session.storage.(interface{ PlayerDropPages() }); ok {
				dropper.PlayerDropPages()
			}
			delete(cursorCloudSessions, key)
		}
	}
}
