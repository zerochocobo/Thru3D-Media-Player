package cloudcore

import (
	"context"
	"errors"
	"path"
	"strings"
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
	items, err := freshCloudList(ctx, s, path.Dir(p))
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
	if target == nil || target.IsDir() != t.Folder || model.ObjHasMask(target, model.NoRename) ||
		(!t.Folder && (target.GetSize() != t.Size || (t.Modified >= 0 && cloudModified(target) != t.Modified))) {
		return errors.New("cloud file changed")
	}
	// Call the pinned driver with a freshly verified object, bypassing generic path rename caches.
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
	err = checkedCloudRename(c.Request.Context(), s, p, t.cloudTarget, t.NewName)
	for key := range cloudSnapshots {
		if strings.HasPrefix(key, t.Mount+"/") {
			delete(cloudSnapshots, key)
		}
	}
	op.Cache.DeleteDirectoryTree(s, "/")
	if err != nil {
		cloudListError(c, "rename115.rename", err)
		return
	}
	c.JSON(200, gin.H{"code": 200, "data": nil})
}
