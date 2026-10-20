package cloudcore

import (
	"context"
	"errors"
	"path"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/gin-gonic/gin"
)

// JNI-only: native filename search, never the UI's full-directory current-scope fallback.
func companions115(c *gin.Context) {
	var req cloudTarget
	if c.ShouldBindJSON(&req) != nil || req.Path == "/" || len(req.FolderID) > 128 || req.FolderID != "" && !cloudID.MatchString(req.FolderID) {
		cloudListError(c, "companions115.request", errors.New("invalid video path"))
		return
	}
	storage, remote, err := targetStorage(req, false)
	if err != nil {
		cloudListError(c, "companions115.storage", err)
		return
	}
	native, ok := storage.(cloudPageDriver)
	searcher, searchable := storage.(nativeCloudSearcher)
	if !ok || !searchable {
		cloudListError(c, "companions115.driver", errors.New("native companion search unavailable"))
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 10*time.Second)
	defer cancel()
	parent := path.Dir(remote)
	var folder model.Obj
	if req.FolderID != "" {
		folder, err = native.PlayerFolder(ctx, parent, req.FolderID)
	} else if cached, exists := cloudFolders[req.Mount+parent]; exists && time.Now().Before(cached.expires) {
		folder = cached.object
	} else {
		folder, err = native.PlayerFolder(ctx, parent, "")
	}
	if err != nil || folder == nil || !folder.IsDir() {
		cloudListError(c, "companions115.folder", errors.New("cloud folder unavailable"))
		return
	}
	objects, err := readCloudCompanions(ctx, searcher, folder, path.Base(remote))
	if err != nil {
		cloudListError(c, "companions115.search", err)
		return
	}
	content := make([]gin.H, 0, len(objects))
	for _, obj := range objects {
		content = append(content, cloudListingObject(storage, obj))
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"content": content}})
}

func readCloudCompanions(ctx context.Context, searcher nativeCloudSearcher, folder model.Obj, video string) ([]model.Obj, error) {
	stem := strings.TrimSuffix(video, path.Ext(video))
	if stem == "" || !utf8.ValidString(stem) || !safeSearchName(stem) {
		return nil, errors.New("invalid companion filename")
	}
	query := []rune(stem)
	if len(query) > 128 {
		query = query[:128] // Search a bounded prefix; the complete stem is still checked below.
	}
	objects := make([]model.Obj, 0)
	cursor := ""
	seenCursors := map[string]bool{}
	seenObjects := map[string]bool{}
	for batch := 0; batch < 209; batch++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		raw, next, _, capped, err := searcher.PlayerSearch(ctx, folder, string(query), "all", cursor)
		if err != nil {
			return nil, err
		}
		for _, obj := range raw {
			parent, ok := obj.(interface{ PlayerParentID() string })
			if !ok {
				return nil, errors.New("companion search missing parent identity")
			}
			if parent.PlayerParentID() != folder.GetID() || obj.IsDir() || obj.GetSize() <= 0 ||
				!safeSearchName(obj.GetName()) || !strings.HasPrefix(strings.ToLower(obj.GetName()), strings.ToLower(stem)+".") {
				continue
			}
			// Discovery preserves all matching sibling types. The audio/subtitle
			// consumer owns format support; future formats need no search-layer edit.
			if obj.GetID() == "" || seenObjects[obj.GetID()] {
				return nil, errors.New("invalid repeated companion object")
			}
			seenObjects[obj.GetID()] = true
			objects = append(objects, obj)
		}
		if capped {
			return nil, errors.New("companion search result limit reached")
		}
		if next == "" {
			return objects, ctx.Err()
		}
		if next == cursor || seenCursors[next] {
			return nil, errors.New("repeated companion search cursor")
		}
		seenCursors[next] = true
		cursor = next
	}
	return nil, errors.New("companion search result limit reached")
}
