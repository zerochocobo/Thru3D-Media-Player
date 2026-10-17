package cloudcore

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/gin-gonic/gin"
)

type cloudNativeMatches interface {
	cloudPageDriver
	cloudParentResolver
	PlayerMatches(context.Context, model.Obj, string) ([]model.Obj, error)
}

func freshWriteObject(ctx context.Context, storage driver.Driver, remote string, selected model.Obj) (model.Obj, error) {
	if verifier, ok := storage.(interface {
		PlayerVerifyTarget(context.Context, string, string) (model.Obj, error)
	}); ok && selected != nil {
		return verifier.PlayerVerifyTarget(ctx, remote, selected.GetID())
	}
	return selected, ctx.Err()
}

// Cached IDs are hints only. Before management reads or writes, resolve the ID's
// actual path afresh so a moved/replaced parent cannot redirect an operation.
func freshMatchParent(ctx context.Context, native cloudNativeMatches, mount, remote, id string) (model.Obj, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if id == "" {
		if cached, ok := cloudFolders[mount+remote]; ok && time.Now().Before(cached.expires) {
			id = cached.object.GetID()
		}
	}
	folder, err := native.PlayerFolder(ctx, remote, id)
	if err != nil {
		return nil, err
	}
	if folder == nil || !folder.IsDir() {
		return nil, missingCloudFolder
	}
	actual, err := native.PlayerSearchParent(ctx, folder.GetID())
	if err != nil {
		return nil, err
	}
	if actual != remote {
		return nil, errors.New("cloud parent changed; refresh the folder")
	}
	if len(cloudFolders) >= 64 {
		for key := range cloudFolders {
			delete(cloudFolders, key)
			break
		}
	}
	cloudFolders[mount+remote] = cloudFolder{object: folder, expires: time.Now().Add(2 * time.Minute)}
	return folder, ctx.Err()
}

func freshCloudCandidates(ctx context.Context, storage driver.Driver, remote string, queries []string, folderID string) ([]model.Obj, error) {
	native, ok := storage.(cloudNativeMatches)
	if !ok {
		return freshCloudList(ctx, storage, remote)
	}
	folder, err := freshMatchParent(ctx, native, storage.GetStorage().MountPath, remote, folderID)
	if err != nil {
		return nil, err
	}
	objects := make([]model.Obj, 0)
	seen := map[string]model.Obj{}
	for _, query := range queries {
		if query == "" || !utf8.ValidString(query) || !safeSearchName(query) {
			return nil, errors.New("invalid cloud candidate query")
		}
		rows, err := native.PlayerMatches(ctx, folder, query)
		if err != nil {
			return nil, err
		}
		for _, obj := range rows {
			if !strings.Contains(strings.ToLower(obj.GetName()), strings.ToLower(query)) {
				continue
			}
			if old, exists := seen[obj.GetID()]; exists {
				if old.GetName() != obj.GetName() || old.GetSize() != obj.GetSize() || old.IsDir() != obj.IsDir() || cloudModified(old) != cloudModified(obj) {
					return nil, errors.New("cloud file changed")
				}
				continue
			}
			seen[obj.GetID()] = obj
			objects = append(objects, obj)
		}
	}
	return objects, ctx.Err()
}

func matches115(c *gin.Context) {
	var req struct {
		cloudTarget
		Queries []string `json:"queries"`
	}
	if c.ShouldBindJSON(&req) != nil || len(req.Queries) < 1 || len(req.Queries) > 2 {
		cloudListError(c, "matches115.request", errors.New("invalid candidate request"))
		return
	}
	for _, query := range req.Queries {
		if len(query) > 4096 || !utf8.ValidString(query) || !safeSearchName(query) {
			cloudListError(c, "matches115.request", errors.New("invalid candidate query"))
			return
		}
	}
	storage, remote, err := targetStorage(req.cloudTarget, false)
	if err != nil {
		cloudListError(c, "matches115.storage", err)
		return
	}
	if _, ok := storage.(cloudNativeMatches); !ok {
		cloudListError(c, "matches115.driver", errors.New("native candidates unavailable"))
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 20*time.Second)
	defer cancel()
	objects, err := freshCloudCandidates(ctx, storage, remote, req.Queries, req.FolderID)
	if err != nil {
		cloudListError(c, "matches115.search", err)
		return
	}
	rows := make([]gin.H, 0, len(objects))
	for _, obj := range objects {
		rows = append(rows, cloudListingObject(storage, obj))
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"content": rows}})
}

func exists115(c *gin.Context) {
	var req cloudTarget
	if c.ShouldBindJSON(&req) != nil {
		cloudError(c)
		return
	}
	storage, _, err := targetStorage(req, true)
	if err != nil {
		cloudListError(c, "exists115.storage", err)
		return
	}
	reader, ok := storage.(interface {
		PlayerObjectExists(context.Context, string) (bool, error)
	})
	if !ok {
		cloudListError(c, "exists115.driver", errors.New("native identity check unavailable"))
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 10*time.Second)
	defer cancel()
	exists, err := reader.PlayerObjectExists(ctx, req.ID)
	if err != nil {
		cloudListError(c, "exists115.lookup", err)
		return
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"exists": exists}})
}
