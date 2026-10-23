package cloudcore

import (
	"context"
	"errors"
	"path"
	"strings"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/gin-gonic/gin"
)

// A generic OpenList Link without Expiration is tied to one HTTP request's
// SyncClosers. Pin the verified object and snapshot its URL/header in our own
// lease so comic ranges never re-enter generic path/link resolution per page.
func comicSourceRoutes(router *gin.Engine) {
	router.POST("/archive-stream", func(g *gin.Context) {
		var q cloudTarget
		if g.ShouldBindJSON(&q) != nil {
			g.JSON(200, gin.H{"code": 400, "message": "Archive source is not supported"})
			return
		}
		var selected model.Obj
		get := func(ctx context.Context, storage driver.Driver, remote string) (model.Obj, error) {
			var e error
			selected, e = comicSourceObject(ctx, storage, q)
			return selected, e
		}
		location, e := comicCloudSource(g.Request.Context(), q, op.GetStorageAndActualPath, get)
		if e != nil {
			g.JSON(200, gin.H{"code": 400, "message": "Archive source is not supported", "error_reason": "cloud_location_expired"})
			return
		}
		g.JSON(200, gin.H{"code": 200, "data": gin.H{"stream": location, "name": selected.GetName(), "id": selected.GetID(), "size": selected.GetSize(), "modified": cloudModified(selected)}})
	})
}

func comicCloudSource(ctx context.Context, q cloudTarget,
	resolve func(string) (driver.Driver, string, error),
	get func(context.Context, driver.Driver, string) (model.Obj, error)) (string, error) {
	if !cloudMount.MatchString(q.Mount) || q.Path == "/" || !strings.HasPrefix(q.Path, "/") || path.Clean(q.Path) != q.Path || strings.ContainsAny(q.Path, "\x00\\") || q.Size < 0 {
		return "", errors.New("invalid archive source")
	}
	storage, actual, e := resolve(q.Mount + q.Path)
	if e != nil || storage == nil || actual != q.Path || storage.GetStorage().MountPath != q.Mount || storage.GetStorage().Disabled {
		return "", errors.New("archive source unavailable")
	}
	file, e := get(ctx, storage, actual)
	if e != nil {
		return "", e
	}
	if file == nil || file.IsDir() || file.GetName() != path.Base(q.Path) || file.GetSize() <= 0 || (q.Size > 0 && file.GetSize() != q.Size) ||
		(q.ID != "" && q.ID != q.Path && file.GetID() != "" && file.GetID() != q.ID) ||
		(q.Modified > 0 && cloudModified(file) > 0 && q.Modified != cloudModified(file)) {
		return "", errors.New("archive source changed")
	}
	return boundPlaybackLeaseURL(storage, q.Mount, actual, file, true)
}

func comicSourceObject(ctx context.Context, storage driver.Driver, q cloudTarget) (model.Obj, error) {
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	var selected model.Obj
	accept := func(obj model.Obj) error {
		if obj.IsDir() || obj.GetName() != path.Base(q.Path) {
			return nil
		}
		if q.ID != "" && q.ID != q.Path && obj.GetID() != q.ID {
			return nil
		}
		if q.Size > 0 && obj.GetSize() != q.Size {
			return nil
		}
		if q.Modified > 0 && cloudModified(obj) > 0 && cloudModified(obj) != q.Modified {
			return nil
		}
		if selected != nil && (selected.GetID() != obj.GetID() || selected.GetSize() != obj.GetSize() || !selected.ModTime().Equal(obj.ModTime())) {
			return errors.New("ambiguous archive source")
		}
		selected = obj
		return nil
	}
	// Retain the exact server-provided object of the visible page. Do not turn a
	// cold open into the generic Get -> full parent List fallback on big folders.
	for key, session := range cursorCloudSessions {
		base, _, _ := strings.Cut(key, "\x00")
		if base != q.Mount+path.Dir(q.Path) || session.storage != storage {
			continue
		}
		for _, page := range session.pages {
			for _, obj := range page.objects {
				if e := accept(obj); e != nil {
					return nil, e
				}
			}
		}
	}
	for _, session := range cloudSearchSessions {
		if session.Storage != storage || session.Request.Mount != q.Mount {
			continue
		}
		for token, obj := range session.Objects {
			if session.Paths[token] == q.Path {
				// Search results use mount-relative paths; path-based Link drivers
				// need their configured source root, as normal listing objects do.
				if root, ok := storage.(driver.IRootPath); ok {
					obj = comicSourcePath{Obj: obj, sourcePath: path.Join("/", root.GetRootPath(), q.Path)}
				}
				if e := accept(obj); e != nil {
					return nil, e
				}
			}
		}
	}
	if selected != nil {
		return selected, nil
	}
	if _, ok := storage.(driver.Getter); ok {
		return op.GetUnwrap(ctx, storage, q.Path)
	}
	return nil, errors.New("archive location expired; refresh the folder")
}

type comicSourcePath struct {
	model.Obj
	sourcePath string
}

func (f comicSourcePath) GetPath() string { return f.sourcePath }
