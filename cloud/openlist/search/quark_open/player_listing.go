package quark_open

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"path"
	"strings"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
)

func (d *QuarkOpen) PlayerFolder(_ context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	if remote == "/" {
		id = d.RootFolderID
	}
	if id == "" || strings.ContainsAny(id, "/\\\x00") {
		return nil, errors.New("directory location expired; open the cloud account again")
	}
	return &model.Object{ID: id, Name: path.Base(remote), Path: remote, IsFolder: true}, nil
}

func (d *QuarkOpen) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	return d.PlayerPageSized(ctx, dir, cursor, order, 48)
}

func (d *QuarkOpen) PlayerPageSized(ctx context.Context, dir model.Obj, cursor, order string, pageSize int) ([]model.Obj, string, int64, error) {
	if pageSize < 1 || pageSize > 100 {
		return nil, "", 0, errors.New("invalid directory page size")
	}
	field, direction := d.OrderBy, d.OrderDirection
	if field == "" || field == "none" {
		field = "file_name"
	}
	switch order {
	case "source":
	case "name_asc", "name_desc":
		field = "file_name"
	case "modified_asc", "modified_desc":
		field = "updated_at"
	default:
		return nil, "", 0, errors.New("directory sort unavailable")
	}
	if order != "source" {
		direction = "asc"
		if strings.HasSuffix(order, "desc") {
			direction = "desc"
		}
	}
	body := map[string]any{"parent_fid": dir.GetID(), "size": pageSize, "sort": field + ":" + direction}
	if cursor != "" {
		var query QueryCursor
		if json.Unmarshal([]byte(cursor), &query) != nil || query.Token == "" {
			return nil, "", 0, errors.New("invalid directory cursor")
		}
		body["query_cursor"] = query
	}
	var resp FileListResp
	_, err := d.request(ctx, "/open/v1/file/list", http.MethodPost, func(r *resty.Request) { r.SetBody(body) }, &resp)
	if err != nil {
		return nil, "", 0, err
	}
	if len(resp.Data.FileList) > pageSize {
		return nil, "", 0, errors.New("invalid directory page")
	}
	objects := make([]model.Obj, 0, len(resp.Data.FileList))
	for _, file := range resp.Data.FileList {
		obj := fileToObj(file)
		obj.Path = path.Join(dir.GetPath(), obj.GetName())
		objects = append(objects, obj)
	}
	next := ""
	if !resp.Data.LastPage {
		if resp.Data.NextQueryCursor.Token == "" {
			return nil, "", 0, errors.New("missing directory cursor")
		}
		encoded, _ := json.Marshal(resp.Data.NextQueryCursor)
		next = string(encoded)
	}
	return objects, next, -1, nil
}
