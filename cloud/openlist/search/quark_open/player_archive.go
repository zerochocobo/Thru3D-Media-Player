package quark_open

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"net/http"
	"strings"
)

func (d *QuarkOpen) PlayerArchiveTarget(ctx context.Context, remote, id string) (model.Obj, *model.Link, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if id == "" || strings.ContainsAny(id, "/\\\x00") {
		return nil, nil, errors.New("archive location expired; refresh the folder")
	}
	var resp FileLikeResp
	_, err := d.request(ctx, "/open/v1/file/get_download_url", http.MethodPost, func(r *resty.Request) { r.SetContext(ctx).SetBody(map[string]string{"fid": id}) }, &resp)
	if err != nil {
		return nil, nil, err
	}
	if resp.Data.Fid != id || resp.Data.Size <= 0 || resp.Data.FileName == "" || resp.Data.DownloadURL == "" {
		return nil, nil, errors.New("archive file missing")
	}
	obj := &model.Object{ID: id, Path: remote, Name: resp.Data.FileName, Size: int64(resp.Data.Size)}
	return obj, &model.Link{URL: resp.Data.DownloadURL, Header: http.Header{"Cookie": []string{d.generateAuthCookie()}}}, nil
}
