package webdav

import (
	"context"
	"errors"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/maruel/natural"
)

type playerDAVKey struct {
	driver *WebDav
	path   string
}
type playerDAVSnapshot struct {
	objects []model.Obj
	ordered []model.Obj
	order   string
	expires time.Time
}

var playerDAVCache = map[playerDAVKey]*playerDAVSnapshot{} // JNI management is serial.

func PlayerDropStorage(id uint) {
	for key := range playerDAVCache {
		if key.driver.GetStorage().ID == id {
			delete(playerDAVCache, key)
		}
	}
}

func (d *WebDav) PlayerDropPages() {
	for key := range playerDAVCache {
		if key.driver == d {
			delete(playerDAVCache, key)
		}
	}
}

func (d *WebDav) PlayerFolder(_ context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	full := path.Join("/", d.RootFolderPath, remote)
	if id == "" {
		id = full
	}
	return &model.Object{ID: id, Path: full, Name: path.Base(full), IsFolder: true}, nil
}
func (d *WebDav) PlayerForget(remote string) {
	delete(playerDAVCache, playerDAVKey{d, path.Join("/", d.RootFolderPath, remote)})
}

func (d *WebDav) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	offset := 0
	if cursor != "" {
		n, err := strconv.Atoi(cursor)
		if err != nil || n < 0 {
			return nil, "", 0, errors.New("invalid directory cursor")
		}
		offset = n
	}
	switch order {
	case "source", "name_asc", "name_desc", "size_asc", "size_desc", "modified_asc", "modified_desc":
	default:
		return nil, "", 0, errors.New("invalid directory sort order")
	}
	key := playerDAVKey{d, dir.GetPath()}
	snapshot := playerDAVCache[key]
	if snapshot == nil || time.Now().After(snapshot.expires) {
		files, err := d.client.PlayerReadDir(ctx, dir.GetPath())
		if err != nil {
			return nil, "", 0, err
		}
		if len(files) > 100000 {
			return nil, "", 0, errors.New("WebDAV directory exceeds metadata cache limit")
		}
		objects := make([]model.Obj, 0, len(files))
		for _, file := range files {
			full := path.Join(dir.GetPath(), file.Name())
			objects = append(objects, &model.Object{ID: full, Path: full, Name: file.Name(), Size: file.Size(), Modified: file.ModTime(), IsFolder: file.IsDir()})
		}
		if err := ctx.Err(); err != nil {
			return nil, "", 0, err
		}
		delete(playerDAVCache, key)
		total := len(objects)
		for _, s := range playerDAVCache {
			total += len(s.objects)
		}
		for len(playerDAVCache) >= 4 || total > 100000 {
			for k, s := range playerDAVCache {
				delete(playerDAVCache, k)
				total -= len(s.objects)
				break
			}
		}
		snapshot = &playerDAVSnapshot{objects: objects, expires: time.Now().Add(2 * time.Minute)}
		playerDAVCache[key] = snapshot
	}
	if snapshot.order != order {
		snapshot.ordered = append([]model.Obj(nil), snapshot.objects...)
		if order != "source" {
			sort.SliceStable(snapshot.ordered, func(i, j int) bool { return playerDAVBefore(snapshot.ordered[i], snapshot.ordered[j], order) })
		}
		snapshot.order = order
	}
	if offset > len(snapshot.ordered) {
		return nil, "", 0, errors.New("directory page expired; refresh the folder")
	}
	end := min(offset+48, len(snapshot.ordered))
	next := ""
	if end < len(snapshot.ordered) {
		next = strconv.Itoa(end)
	}
	return append([]model.Obj(nil), snapshot.ordered[offset:end]...), next, int64(len(snapshot.ordered)), nil
}

func playerDAVBefore(a, b model.Obj, order string) bool {
	if a.IsDir() != b.IsDir() {
		return a.IsDir()
	}
	field := strings.Split(order, "_")[0]
	desc := strings.HasSuffix(order, "desc")
	if field == "modified" || field == "size" && !a.IsDir() {
		av, bv := a.GetSize(), b.GetSize()
		if field == "modified" {
			av, bv = a.ModTime().UnixMilli(), b.ModTime().UnixMilli()
			if a.ModTime().IsZero() {
				av = -1
			}
			if b.ModTime().IsZero() {
				bv = -1
			}
		}
		if (av < 0) != (bv < 0) {
			return av >= 0
		}
		if av != bv {
			if desc {
				return av > bv
			}
			return av < bv
		}
	}
	left, right := strings.ToLower(a.GetName()), strings.ToLower(b.GetName())
	if left == right || !natural.Less(left, right) && !natural.Less(right, left) {
		return a.GetID() < b.GetID()
	}
	if field == "name" && desc {
		return natural.Less(right, left)
	}
	return natural.Less(left, right)
}
