package _123_open

// Adapt the pinned OpenList 123 Open driver to the player's cursor interface.
// The official v2 list endpoint has lastFileId pagination, not global sorting.
import (
	"context"
	"errors"
	"net/http"
	"path"
	"strconv"
	"strings"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
)

func player123ID(value string) (int64, error) {
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n < 0 || strconv.FormatInt(n, 10) != value {
		return 0, errors.New("invalid 123 directory ID")
	}
	return n, nil
}

func (d *Open123) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	if remote == "/" {
		id = d.RootFolderID
	}
	if id != "" {
		if _, err := player123ID(id); err != nil {
			return nil, err
		}
		return &model.Object{ID: id, Path: remote, Name: path.Base(remote), IsFolder: true}, nil
	}
	// Restored paths and companion readers may not carry a folder ID. Resolve
	// them with bounded pages instead of replaying an unbounded full listing.
	var folder model.Obj = &model.Object{ID: d.RootFolderID, IsFolder: true}
	budget := 200
	for _, name := range strings.Split(strings.TrimPrefix(remote, "/"), "/") {
		cursor := ""
		var found model.Obj
		seen := map[string]bool{}
		for {
			if budget == 0 {
				return nil, errors.New("directory location expired; reopen the cloud account")
			}
			budget--
			rows, next, _, err := d.PlayerPageSized(ctx, folder, cursor, "source", 100)
			if err != nil {
				return nil, err
			}
			for _, row := range rows {
				if row.GetName() == name && row.IsDir() {
					if found != nil {
						return nil, errors.New("ambiguous cloud folder")
					}
					found = row
				}
			}
			if next == "" {
				break
			}
			if seen[next] {
				return nil, errors.New("directory cursor cycle")
			}
			seen[next] = true
			cursor = next
		}
		if found == nil {
			return nil, errors.New("cloud folder not found")
		}
		folder = found
	}
	return folder, nil
}

func (d *Open123) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	return d.PlayerPageSized(ctx, dir, cursor, order, 48)
}

func (d *Open123) PlayerPageSized(ctx context.Context, dir model.Obj, cursor, order string, pageSize int) ([]model.Obj, string, int64, error) {
	if err := ctx.Err(); err != nil {
		return nil, "", 0, err
	}
	if pageSize < 1 || pageSize > 100 || order != "source" {
		return nil, "", 0, errors.New("unsupported 123 directory page size or order")
	}
	parent, err := player123ID(dir.GetID())
	if err != nil {
		return nil, "", 0, err
	}
	last := int64(0)
	if cursor != "" {
		last, err = player123ID(cursor)
		if err != nil || last == 0 {
			return nil, "", 0, errors.New("invalid directory cursor")
		}
	}
	var resp FileListResp
	_, err = d.Request(FileList, http.MethodGet, func(r *resty.Request) {
		r.SetContext(ctx).SetQueryParams(map[string]string{
			"parentFileId": strconv.FormatInt(parent, 10), "limit": strconv.Itoa(pageSize),
			"lastFileId": strconv.FormatInt(last, 10), "trashed": "false",
		})
	}, &resp)
	if err != nil {
		return nil, "", 0, err
	}
	if len(resp.Data.FileList) > pageSize || resp.Data.LastFileId < -1 || resp.Data.LastFileId != -1 && resp.Data.LastFileId <= last {
		return nil, "", 0, errors.New("invalid 123 directory page or cursor")
	}
	rows := make([]model.Obj, 0, len(resp.Data.FileList))
	seen := map[int64]bool{}
	for _, file := range resp.Data.FileList {
		if file.FileId <= 0 || seen[file.FileId] {
			return nil, "", 0, errors.New("invalid or duplicate 123 file ID")
		}
		seen[file.FileId] = true
		// Upstream also filters trashed rows: the API can ignore this parameter.
		if file.Trashed == 0 {
			rows = append(rows, file)
		}
	}
	next := ""
	if resp.Data.LastFileId != -1 {
		next = strconv.FormatInt(resp.Data.LastFileId, 10)
	}
	return rows, next, -1, ctx.Err()
}
