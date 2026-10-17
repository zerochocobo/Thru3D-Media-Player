package cloudcore

import (
	"context"
	"errors"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/gin-gonic/gin"
)

var cloudMount = regexp.MustCompile(`^/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var missingCloudFolder = errors.New("cloud folder not found")
var cloudID = regexp.MustCompile(`^[1-9][0-9]*$`)

// These routes are JNI-only. Never register them on the HTTP stream router.
func deletionRoutes(router *gin.Engine) {
	router.POST("/list115", list115)
	router.POST("/stat115", stat115)
	router.POST("/companions115", companions115)
	router.POST("/matches115", matches115)
	router.POST("/exists115", exists115)
	router.POST("/remove115", remove115)
	router.POST("/rename115", rename115)
}

type cloudTarget struct {
	Mount    string `json:"mount"`
	Path     string `json:"path"`
	ID       string `json:"id"`
	Folder   bool   `json:"folder"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
	FolderID string `json:"folder_id"`
}

func targetStorage(t cloudTarget, deleting bool) (driver.Driver, string, error) {
	if !cloudMount.MatchString(t.Mount) || !strings.HasPrefix(t.Path, "/") || path.Clean(t.Path) != t.Path || strings.ContainsAny(t.Path, "\x00\\") || len(t.FolderID) > 128 || t.FolderID != "" && !cloudID.MatchString(t.FolderID) || (deleting && (t.Path == "/" || !cloudID.MatchString(t.ID))) {
		return nil, "", errors.New("invalid cloud target")
	}
	s, actual, err := op.GetStorageAndActualPath(t.Mount + t.Path)
	if err != nil || s == nil || s.GetStorage().MountPath != t.Mount || s.Config().Name != "115 Open" || s.GetStorage().Disabled || actual != t.Path {
		return nil, "", errors.New("cloud deletion unavailable")
	}
	return s, actual, nil
}

// Walk fresh objects from the root: op.Get(non-root) would reuse stale parent IDs.
func freshCloudList(ctx context.Context, s driver.Driver, p string) ([]model.Obj, error) {
	current, err := op.Get(ctx, s, "/")
	if err != nil {
		return nil, err
	}
	if p != "/" {
		for _, name := range strings.Split(strings.TrimPrefix(p, "/"), "/") {
			items, err := s.List(ctx, current, model.ListArgs{Refresh: true})
			if err != nil {
				return nil, err
			}
			current = nil
			for _, item := range items {
				if item.GetName() == name {
					if current != nil {
						return nil, errors.New("ambiguous cloud folder")
					}
					current = item
				}
			}
			if current == nil || !current.IsDir() {
				return nil, missingCloudFolder
			}
		}
	}
	return s.List(ctx, current, model.ListArgs{Refresh: true})
}

func cloudModified(obj model.Obj) int64 {
	if obj.ModTime().IsZero() {
		return -1
	}
	return obj.ModTime().UnixMilli()
}

func checkedCloudRemove(ctx context.Context, s driver.Driver, p string, t cloudTarget) error {
	if p == "/" || path.Clean(p) != p || !cloudID.MatchString(t.ID) {
		return errors.New("invalid cloud target")
	}
	items, err := freshCloudCandidates(ctx, s, path.Dir(p), []string{path.Base(p)}, t.FolderID)
	if err != nil {
		return err
	}
	var target model.Obj
	for _, item := range items {
		if item.GetName() == path.Base(p) {
			if target != nil {
				return errors.New("ambiguous cloud file")
			}
			target = item
		}
	}
	target, err = freshWriteObject(ctx, s, p, target)
	if err != nil {
		return err
	}
	if target == nil || target.GetID() != t.ID || target.GetName() != path.Base(p) || target.IsDir() != t.Folder || model.ObjHasMask(target, model.NoRemove) || (!t.Folder && (target.GetSize() != t.Size || (t.Modified >= 0 && cloudModified(target) != t.Modified))) {
		return errors.New("cloud file changed")
	}
	remover, ok := s.(driver.Remove)
	if !ok {
		return errors.New("cloud deletion unavailable")
	}
	// One ordinary deletion of the verified object. No child-by-child removal,
	// recycle-bin purge, or replay after an ambiguous transport error.
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := remover.Remove(ctx, target); err != nil {
		return &cloudRemoveAttempt{err}
	}
	return nil
}

type cloudRemoveAttempt struct{ error }

func cloudRemoveError(c *gin.Context, err error, started bool) {
	reason := "failed"
	if errors.Is(err, missingCloudFolder) || err.Error() == "cloud file changed" || err.Error() == "ambiguous cloud file" || err.Error() == "ambiguous cloud folder" {
		reason = "changed"
	}
	c.JSON(200, gin.H{"code": 500, "message": "Cloud request failed", "delete_started": started, "delete_reason": reason})
}

func invalidateCloudRemoval(s driver.Driver, mount, p string) {
	parent := mount + path.Dir(p)
	target := mount + p
	for key := range cloudSnapshots {
		base, _, _ := strings.Cut(key, "\x00")
		if base == parent || base == target || strings.HasPrefix(base, target+"/") || (path.Dir(p) == "/" && strings.HasPrefix(base, mount+"/")) {
			delete(cloudSnapshots, key)
		}
	}
	for key := range cloudFolders {
		if key == target || strings.HasPrefix(key, target+"/") || (path.Dir(p) == "/" && strings.HasPrefix(key, mount+"/")) {
			delete(cloudFolders, key)
		}
	}
	// A child removal does not replace its ancestors. Keep unrelated/root snapshots
	// rather than force the next parent refresh to query the root twice.
	op.Cache.DeleteDirectoryTree(s, path.Dir(p))
}

func remove115(c *gin.Context) {
	var t cloudTarget
	if c.ShouldBindJSON(&t) != nil {
		cloudRemoveError(c, errors.New("invalid cloud target"), false)
		return
	}
	s, p, err := targetStorage(t, true)
	if err != nil {
		cloudRemoveError(c, err, false)
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 20*time.Second)
	defer cancel()
	err = checkedCloudRemove(ctx, s, p, t)
	var attempted *cloudRemoveAttempt
	started := errors.As(err, &attempted)
	if err == nil || started {
		invalidateCloudRemoval(s, t.Mount, p)
	}
	if err != nil {
		cloudRemoveError(c, err, started)
		return
	}
	c.JSON(200, gin.H{"code": 200, "data": nil})
}

func cloudError(c *gin.Context) { c.JSON(200, gin.H{"code": 500, "message": "Cloud request failed"}) }
