package cloudcore

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/gin-gonic/gin"
	"path"
	"strconv"
	"strings"
	"time"
)

type cloudSnapshot struct {
	objects           []model.Obj
	expires           time.Time
	total             int64
	folderID          string
	resolution        string
	resolveMs, listMs int64
	cacheHit          bool
}

var cloudSnapshots = map[string]cloudSnapshot{} // Request serializes all JNI requests.

type cloudPageDriver interface {
	PlayerListPage(context.Context, model.Obj, int64, string) ([]model.Obj, int64, error)
	PlayerLookup(context.Context, string) (model.Obj, error)
	PlayerFolder(context.Context, string, string) (model.Obj, error)
}

type cloudFolder struct {
	object  model.Obj
	expires time.Time
}

var cloudFolders = map[string]cloudFolder{}

func invalidateCloudPages(mount, remote string) {
	target := mount + remote
	if remote == "/" {
		target = mount
	}
	for key := range cloudSnapshots {
		base, _, _ := strings.Cut(key, "\x00")
		if base == target || strings.HasPrefix(base, target+"/") {
			delete(cloudSnapshots, key)
		}
	}
	for key := range cloudFolders {
		if key == target || strings.HasPrefix(key, target+"/") {
			delete(cloudFolders, key)
		}
	}
}

func cloudListingObject(s driver.Driver, item model.Obj) gin.H {
	_, renameResult := s.(driver.RenameResult)
	_, renameOnly := s.(driver.Rename)
	return gin.H{"name": item.GetName(), "id": item.GetID(), "is_dir": item.IsDir(), "size": item.GetSize(), "modified_ms": cloudModified(item),
		"can_delete": cloudID.MatchString(item.GetID()) && !model.ObjHasMask(item, model.NoRemove),
		"can_rename": (renameResult || renameOnly) && cloudID.MatchString(item.GetID()) && !model.ObjHasMask(item, model.NoRename)}
}

func list115(c *gin.Context) {
	var t struct {
		cloudTarget
		Offset  int    `json:"offset"`
		Refresh bool   `json:"refresh"`
		Order   string `json:"order"`
	}
	if c.ShouldBindJSON(&t) != nil || t.Offset < 0 || t.Offset > 2147483647-48 || len(t.FolderID) > 128 || t.FolderID != "" && !cloudID.MatchString(t.FolderID) {
		cloudListError(c, "list115.request", errors.New("invalid directory page request"))
		return
	}
	s, p, err := targetStorage(t.cloudTarget, false)
	if err != nil {
		cloudListError(c, "list115.storage", err)
		return
	}
	native, ok := s.(cloudPageDriver)
	if !ok {
		cloudListError(c, "list115.driver", errors.New("native directory paging unavailable"))
		return
	}
	switch t.Order {
	case "", "source", "name_asc", "name_desc", "size_asc", "size_desc", "modified_asc", "modified_desc":
	default:
		cloudListError(c, "list115.order", errors.New("invalid directory sort order"))
		return
	}
	snapshot, err := readCloudListing(c.Request.Context(), native, t.Mount, p, t.Offset, t.Order, t.Refresh, t.FolderID)
	if err != nil {
		cloudListError(c, "list115.list", err)
		return
	}
	content := make([]gin.H, 0, len(snapshot.objects))
	for _, item := range snapshot.objects {
		content = append(content, cloudListingObject(s, item))
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"content": content, "total": snapshot.total,
		"paging": gin.H{"folder": snapshot.resolution, "resolve_ms": snapshot.resolveMs, "list_ms": snapshot.listMs, "cache_hit": snapshot.cacheHit}}})
}

func readCloudListing(ctx context.Context, native cloudPageDriver, mount, p string, offset int, order string, refresh bool, folderID string) (cloudSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return cloudSnapshot{}, err
	}
	if refresh {
		invalidateCloudPages(mount, p)
	}
	if folder, exists := cloudFolders[mount+p]; exists && folderID != "" && folder.object.GetID() != folderID {
		invalidateCloudPages(mount, p)
	}
	key := mount + p + "\x00" + order + "\x00" + strconv.Itoa(offset)
	snapshot, ok := cloudSnapshots[key]
	if ok && folderID != "" && snapshot.folderID != folderID {
		invalidateCloudPages(mount, p)
		ok = false
	}
	if !ok || time.Now().After(snapshot.expires) {
		started := time.Now()
		resolution := "memory"
		folderKey := mount + p
		folder, exists := cloudFolders[folderKey]
		if !exists || time.Now().After(folder.expires) || folderID != "" && folder.object.GetID() != folderID {
			resolution = "provided_id"
			if p == "/" {
				resolution = "root"
			} else if folderID == "" {
				resolution = "path_lookup"
			}
			obj, e := native.PlayerFolder(ctx, p, folderID)
			if e != nil {
				return cloudSnapshot{}, e
			}
			if obj == nil || !obj.IsDir() {
				return cloudSnapshot{}, missingCloudFolder
			}
			if len(cloudFolders) >= 64 {
				for k := range cloudFolders {
					delete(cloudFolders, k)
					break
				}
			}
			folder = cloudFolder{obj, time.Now().Add(2 * time.Minute)}
			cloudFolders[folderKey] = folder
		}
		resolveMs := time.Since(started).Milliseconds()
		started = time.Now()
		items, total, e := native.PlayerListPage(ctx, folder.object, int64(offset), order)
		if e != nil {
			return cloudSnapshot{}, e
		}
		if total < 0 || total > 2147483647 || int64(offset) > total || len(items) > 48 ||
			int64(offset+len(items)) > total || (len(items) == 0 && int64(offset) < total) {
			return cloudSnapshot{}, errors.New("invalid directory page response; refresh the folder")
		}
		if err := ctx.Err(); err != nil {
			return cloudSnapshot{}, err
		}
		if len(cloudSnapshots) >= 64 {
			for k := range cloudSnapshots {
				delete(cloudSnapshots, k)
				break
			}
		}
		snapshot = cloudSnapshot{objects: items, expires: time.Now().Add(2 * time.Minute), total: total,
			folderID: folder.object.GetID(), resolution: resolution, resolveMs: resolveMs, listMs: time.Since(started).Milliseconds()}
		cloudSnapshots[key] = snapshot
	} else {
		snapshot.cacheHit = true
		snapshot.resolution = "memory"
		snapshot.resolveMs, snapshot.listMs = 0, 0
	}
	return snapshot, nil
}

func stat115(c *gin.Context) {
	var t cloudTarget
	if c.ShouldBindJSON(&t) != nil || len(t.FolderID) > 128 || t.FolderID != "" && !cloudID.MatchString(t.FolderID) {
		cloudListError(c, "stat115.request", errors.New("invalid cloud path"))
		return
	}
	s, p, err := targetStorage(t, false)
	if err != nil {
		cloudListError(c, "stat115.storage", err)
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
	defer cancel()
	started := time.Now()
	reader, readable := s.(cloudPlaybackReader)
	if !readable || t.ID != "" && !cloudID.MatchString(t.ID) {
		cloudListError(c, "stat115.driver", errors.New("native playback lookup unavailable"))
		return
	}
	obj, err := reader.PlayerPlaybackTarget(ctx, p, t.ID)
	if err != nil {
		cloudListError(c, "stat115.lookup", err)
		return
	}
	if parent, ok := obj.(interface{ PlayerParentID() string }); ok && (parent.PlayerParentID() == "0" || cloudID.MatchString(parent.PlayerParentID())) {
		if len(cloudFolders) >= 64 {
			for key := range cloudFolders {
				delete(cloudFolders, key)
				break
			}
		}
		cloudFolders[t.Mount+path.Dir(p)] = cloudFolder{object: &model.Object{ID: parent.PlayerParentID(), Name: path.Base(path.Dir(p)), IsFolder: true}, expires: time.Now().Add(2 * time.Minute)}
	}
	location, err := playbackLeaseURL(s, t.Mount, p, obj)
	if err != nil {
		cloudListError(c, "stat115.stream", err)
		return
	}
	mode := "exact_path"
	if t.ID != "" {
		mode = "object_id"
	}
	c.JSON(200, gin.H{"code": 200, "data": cloudListingObject(s, obj), "stream": location, "lookup": gin.H{"folder": mode, "elapsed_ms": time.Since(started).Milliseconds()}})
}

type cloudChildLookup interface {
	PlayerLookupChild(context.Context, model.Obj, string) (model.Obj, error)
}

func lookupCloudFile(ctx context.Context, native cloudPageDriver, mount, remote, folderID string) (model.Obj, string, error) {
	if err := ctx.Err(); err != nil {
		return nil, "", err
	}
	if remote == "/" {
		obj, err := native.PlayerFolder(ctx, "/", "")
		return obj, "root", err
	}
	child, ok := native.(cloudChildLookup)
	if !ok {
		obj, err := native.PlayerLookup(ctx, remote)
		return obj, "path_lookup", err
	}
	parent, mode := path.Dir(remote), "provided_id"
	var folder model.Obj
	var err error
	if folderID != "" || parent == "/" {
		if parent == "/" {
			mode = "root"
		}
		folder, err = native.PlayerFolder(ctx, parent, folderID)
	} else if cached, exists := cloudFolders[mount+parent]; exists && time.Now().Before(cached.expires) {
		folder, mode = cached.object, "memory"
	} else {
		obj, err := native.PlayerLookup(ctx, remote)
		return obj, "path_lookup", err
	}
	if err != nil {
		return nil, mode, err
	}
	if folder == nil || !folder.IsDir() {
		return nil, mode, missingCloudFolder
	}
	obj, err := child.PlayerLookupChild(ctx, folder, path.Base(remote))
	return obj, mode, err
}
