package aliyundrive_open

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"net/http"
	"strings"
)

func (d *AliyundriveOpen) PlayerArchiveTarget(ctx context.Context, remote, id string) (model.Obj, *model.Link, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	endpoint := "/adrive/v1.0/openFile/get"
	body := base.Json{"drive_id": d.DriveId, "file_id": id}
	if id == "" {
		if d.RootFolderID != "root" {
			return nil, nil, errors.New("archive location expired; refresh the folder")
		}
		endpoint = "/adrive/v1.0/openFile/get_by_path"
		body = base.Json{"drive_id": d.DriveId, "file_path": remote}
	} else if strings.ContainsAny(id, "/\\\x00") {
		return nil, nil, errors.New("invalid archive identity")
	}
	var file File
	_, err := d.request(ctx, limiterOther, endpoint, http.MethodPost, func(r *resty.Request) { r.SetContext(ctx).SetBody(body).SetResult(&file) })
	if err != nil {
		return nil, nil, err
	}
	if file.FileId == "" || file.Type != "file" || id != "" && file.FileId != id {
		return nil, nil, errors.New("archive file missing")
	}
	obj := fileToObj(file)
	obj.Path = remote
	return obj, nil, nil
}
