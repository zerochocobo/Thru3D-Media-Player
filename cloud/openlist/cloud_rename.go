package cloudcore

import (
	"context"
	"errors"
	"path"
	"strings"
	"time"
	"unicode"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/gin-gonic/gin"
)

func checkedCloudRename(ctx context.Context, s driver.Driver, p string, t cloudTarget, name string) error {
	if p == "/" || path.Clean(p) != p || !cloudID.MatchString(t.ID) || name == "" || name != strings.TrimSpace(name) ||
		len(name) > 240 || strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".") || strings.ContainsAny(name, "/\\:*?\"<>|") ||
		strings.IndexFunc(name, unicode.IsControl) >= 0 || (!t.Folder && path.Ext(name) != path.Ext(p)) {
		return errors.New("invalid rename target")
	}
	items, err := freshCloudCandidates(ctx, s, path.Dir(p), []string{path.Base(p), name}, t.FolderID)
	if err != nil {
		return err
	}
	var target model.Obj
	for _, item := range items {
		if strings.EqualFold(item.GetName(), name) {
			return errors.New("rename destination already exists")
		}
		if item.GetID() == t.ID && item.GetName() == path.Base(p) {
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
	if target == nil || target.GetID() != t.ID || target.GetName() != path.Base(p) || target.IsDir() != t.Folder || model.ObjHasMask(target, model.NoRename) ||
		(!t.Folder && (target.GetSize() != t.Size || (t.Modified >= 0 && cloudModified(target) != t.Modified))) {
		return errors.New("cloud file changed")
	}
	// Call the pinned driver with a freshly verified object, bypassing generic path rename caches.
	if err := ctx.Err(); err != nil {
		return err
	}
	if renamer, ok := s.(driver.RenameResult); ok {
		_, err = renamer.Rename(ctx, target, name)
		return err
	}
	if renamer, ok := s.(driver.Rename); ok {
		return renamer.Rename(ctx, target, name)
	}
	return errors.New("cloud rename unavailable")
}

func rename115(c *gin.Context) {
	var t struct {
		cloudTarget
		NewName string `json:"new_name"`
	}
	if c.ShouldBindJSON(&t) != nil {
		cloudError(c)
		return
	}
	s, p, err := targetStorage(t.cloudTarget, true)
	if err != nil {
		cloudListError(c, "rename115.storage", err)
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 20*time.Second)
	defer cancel()
	err = checkedCloudRename(ctx, s, p, t.cloudTarget, t.NewName)
	invalidateCloudPages(t.Mount, "/")
	op.Cache.DeleteDirectoryTree(s, "/")
	if err != nil {
		cloudListError(c, "rename115.rename", err)
		return
	}
	c.JSON(200, gin.H{"code": 200, "data": nil})
}
