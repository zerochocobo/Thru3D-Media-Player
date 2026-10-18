package _115_open

import (
	"context"
	"errors"
	"path"
	"strconv"
	"strings"

	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

// Browsing already has a provider-issued folder ID from its parent page or the
// saved navigation stack. Only legacy locations without an ID need name lookup.
func (d *Open115) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid cloud folder path")
	}
	if remote == "/" {
		return &Obj{Fid: d.GetRootId(), Fc: "0"}, nil
	}
	if id == "" {
		return d.PlayerLookup(ctx, remote)
	}
	if len(id) > 128 || id[0] == '0' || strings.Trim(id, "0123456789") != "" {
		return nil, errors.New("invalid cloud folder ID")
	}
	return &Obj{Fid: id, Fn: path.Base(remote), Fc: "0"}, nil
}

// This path deliberately bypasses List: List collects the whole directory.
// Ordering belongs to 115, before the page is selected, including filename collation.
func (d *Open115) PlayerListPage(ctx context.Context, dir model.Obj, offset int64, order string) ([]model.Obj, int64, error) {
	field, asc := d.OrderBy, d.OrderDirection == "asc"
	switch order {
	case "", "source":
	case "name_asc", "name_desc":
		field, asc = "file_name", order == "name_asc"
	case "size_asc", "size_desc":
		field, asc = "file_size", order == "size_asc"
	case "modified_asc", "modified_desc":
		field, asc = "user_utime", order == "modified_asc"
	default:
		return nil, 0, errors.New("invalid directory sort order")
	}
	if offset < 0 || !dir.IsDir() {
		return nil, 0, errors.New("invalid directory page request")
	}
	if err := d.WaitLimit(ctx); err != nil {
		return nil, 0, err
	}
	resp, err := d.client.GetFiles(ctx, &sdk.GetFilesReq{
		CID: dir.GetID(), Offset: offset, Limit: 48, O: field, ASC: asc, Cur: 1, ShowDir: true,
	})
	if err != nil {
		return nil, 0, err
	}
	if resp.Count < 0 || resp.Offset != offset || len(resp.Data) > 48 || offset > resp.Count ||
		offset+int64(len(resp.Data)) > resp.Count || (len(resp.Data) == 0 && offset < resp.Count) {
		return nil, 0, errors.New("invalid directory page response; refresh the folder")
	}
	objects := make([]model.Obj, 0, len(resp.Data))
	seen := make(map[string]bool)
	for _, raw := range resp.Data {
		obj := Obj(raw)
		if obj.GetID() == "" || seen[obj.GetID()] {
			return nil, 0, errors.New("directory page contains invalid or repeated object IDs")
		}
		seen[obj.GetID()] = true
		objects = append(objects, &obj)
	}
	return objects, resp.Count, nil
}

// Resolve exact direct-child names through native search. Never enumerate a
// parent directory just to open a child. Checking all matching search results
// retains the existing rejection of ambiguous file/folder paths across pages.
func (d *Open115) PlayerLookup(ctx context.Context, remote string) (model.Obj, error) {
	current := model.Obj(&Obj{Fid: d.GetRootId(), Fc: "0"})
	if remote == "/" {
		return current, nil
	}
	for _, name := range strings.Split(strings.TrimPrefix(remote, "/"), "/") {
		var err error
		current, err = d.PlayerLookupChild(ctx, current, name)
		if err != nil {
			return nil, err
		}
	}
	return current, nil
}

// Playback already knows the parent identity from browsing. Do not search short
// ancestor names (such as V) across their descendants before opening one file.
func (d *Open115) PlayerLookupChild(ctx context.Context, dir model.Obj, name string) (model.Obj, error) {
	objects, err := d.PlayerMatches(ctx, dir, name)
	if err != nil {
		return nil, err
	}
	var found model.Obj
	for _, obj := range objects {
		if obj.GetName() != name {
			continue
		}
		if found != nil {
			return nil, errors.New("ambiguous cloud path; rename duplicate names in cloud storage")
		}
		found = obj
	}
	if found == nil {
		return nil, errors.New("cloud file or folder not found")
	}
	return found, nil
}

// Native candidate search retains complete direct-child results, including folders
// and sidecar formats. It never enumerates unrelated directory pages.
func (d *Open115) PlayerMatches(ctx context.Context, dir model.Obj, query string) ([]model.Obj, error) {
	objects, limited, err := d.playerMatches(ctx, dir, query, 10000)
	if err == nil && limited {
		return nil, errors.New("cloud path lookup exceeds search limit")
	}
	return objects, err
}

// User search is deliberately bounded. Exact path and management lookups keep
// using PlayerMatches so truncation cannot hide ambiguous names or companions.
func (d *Open115) PlayerSearchCurrent(ctx context.Context, dir model.Obj, query string) ([]model.Obj, bool, error) {
	return d.playerMatches(ctx, dir, query, playerSearchLimit)
}

func (d *Open115) playerMatches(ctx context.Context, dir model.Obj, query string, limit int64) ([]model.Obj, bool, error) {
	if dir == nil || !dir.IsDir() || !playerSafeName(query) {
		return nil, false, errors.New("invalid cloud match request")
	}
	search := []rune(query)
	if len(search) > 128 {
		search = search[:128]
	}
	objects := make([]model.Obj, 0)
	seen := map[string]bool{}
	offset := int64(0)
	pages := 0
	for {
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		if err := d.WaitLimit(ctx); err != nil {
			return nil, false, err
		}
		pageLimit := min(48, limit-offset)
		resp, err := d.client.SearchFiles(ctx, &sdk.SearchFilesReq{CID: dir.GetID(), SearchValue: string(search), Offset: offset, Limit: pageLimit})
		if err != nil {
			return nil, false, err
		}
		if resp.Offset != offset || resp.Count < 0 || int64(len(resp.Data)) > pageLimit || offset+int64(len(resp.Data)) > resp.Count || (len(resp.Data) == 0 && offset < resp.Count) {
			return nil, false, errors.New("invalid cloud path lookup response")
		}
		for _, item := range resp.Data {
			if item.AreaID != "" && item.AreaID != "1" {
				continue
			}
			if item.ParentID != dir.GetID() || !strings.Contains(strings.ToLower(item.FileName), strings.ToLower(query)) {
				continue
			}
			if !playerSafeName(item.FileName) || item.FileID == "" || seen[item.FileID] {
				return nil, false, errors.New("invalid repeated cloud match")
			}
			obj, err := playerLookupObjects(item.FileID, item.FileName, item.FileSize, item.FileCategory, item.PickCode, item.UserUtime)
			if err != nil {
				return nil, false, err
			}
			obj.(*Obj).Pid = item.ParentID
			seen[item.FileID] = true
			objects = append(objects, obj)
		}
		offset += int64(len(resp.Data))
		pages++
		if offset >= resp.Count {
			return objects, false, ctx.Err()
		}
		if offset >= limit || limit == playerSearchLimit && pages >= 5 {
			return objects, true, ctx.Err()
		}
	}
}

func playerLookupObjects(id, name, rawSize, category, pickCode, modified string) (model.Obj, error) {
	if rawSize == "" && category == "0" {
		rawSize = "0"
	}
	size, err := strconv.ParseInt(rawSize, 10, 64)
	if id == "" || err != nil || size < 0 {
		return nil, errors.New("invalid cloud path object metadata")
	}
	timestamp, _ := strconv.ParseInt(modified, 10, 64)
	return &Obj{Fid: id, Fn: name, FS: size, Fc: category, Pc: pickCode, Upt: timestamp}, nil
}
