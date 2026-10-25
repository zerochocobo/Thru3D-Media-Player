package onedrive

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"net/http"
	"net/url"
	"path"
	"time"
)

func (d *Onedrive) PlayerArchiveTarget(ctx context.Context, remote, id string) (model.Obj, *model.Link, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	full := path.Join("/", d.RootFolderPath, remote)
	var file struct {
		File
		Modified time.Time `json:"lastModifiedDateTime"`
	}
	_, err := d.Request(d.GetMetaUrl(false, full), http.MethodGet, func(r *resty.Request) { r.SetContext(ctx) }, &file)
	if err != nil {
		return nil, nil, err
	}
	if file.Id == "" || file.File.File == nil || file.Size <= 0 || file.Url == "" || id != "" && file.Id != id {
		return nil, nil, errors.New("archive file missing or replaced")
	}
	modified := file.Modified
	if modified.IsZero() && file.FileSystemInfo != nil {
		modified = file.FileSystemInfo.LastModifiedDateTime
	}
	obj := &model.Object{ID: file.Id, Path: full, Name: file.Name, Size: file.Size, Modified: modified}
	location := file.Url
	if d.CustomHost != "" {
		u, err := url.Parse(location)
		if err != nil {
			return nil, nil, err
		}
		u.Host = d.CustomHost
		location = u.String()
	}
	return obj, &model.Link{URL: location}, nil
}
