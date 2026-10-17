package aliyundrive_open

import (
	"context"
	"errors"
	"net/http"
	"path"
	"strings"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
)

func (d *AliyundriveOpen) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	if remote == "/" {
		return &model.Object{ID: d.RootFolderID, Path: "/", IsFolder: true}, nil
	}
	if id != "" && !strings.ContainsAny(id, "/\\\x00") {
		return &model.Object{ID: id, Path: remote, Name: path.Base(remote), IsFolder: true}, nil
	}
	if d.RootFolderID != "root" {
		return nil, errors.New("directory location expired; open the cloud account again")
	}
	var file File
	_, err := d.request(ctx, limiterOther, "/adrive/v1.0/openFile/get_by_path", http.MethodPost, func(r *resty.Request) {
		r.SetContext(ctx).SetBody(base.Json{"drive_id": d.DriveId, "file_path": remote}).SetResult(&file)
	})
	if err != nil {
		return nil, err
	}
	if file.FileId == "" || file.Type != "folder" {
		return nil, errors.New("cloud folder not found")
	}
	obj := fileToObj(file)
	obj.Path = remote
	return obj, nil
}

func (d *AliyundriveOpen) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	field, direction := d.OrderBy, d.OrderDirection
	switch order {
	case "source":
	case "name_asc", "name_desc":
		field = "name"
	case "size_asc", "size_desc":
		field = "size"
	case "modified_asc", "modified_desc":
		field = "updated_at"
	default:
		return nil, "", 0, errors.New("invalid directory sort order")
	}
	if order != "source" {
		direction = "ASC"
		if strings.HasSuffix(order, "desc") {
			direction = "DESC"
		}
	}
	var resp Files
	_, err := d.request(ctx, limiterList, "/adrive/v1.0/openFile/list", http.MethodPost, func(r *resty.Request) {
		r.SetContext(ctx).SetBody(base.Json{"drive_id": d.DriveId, "parent_file_id": dir.GetID(), "limit": 48, "marker": cursor, "order_by": field, "order_direction": direction}).SetResult(&resp)
	})
	if err != nil {
		return nil, "", 0, err
	}
	if len(resp.Items) > 48 || resp.NextMarker != "" && resp.NextMarker == cursor {
		return nil, "", 0, errors.New("invalid directory page")
	}
	objects := make([]model.Obj, 0, len(resp.Items))
	for _, file := range resp.Items {
		obj := fileToObj(file)
		obj.Path = path.Join(dir.GetPath(), obj.GetName())
		objects = append(objects, obj)
	}
	return objects, resp.NextMarker, -1, nil
}
