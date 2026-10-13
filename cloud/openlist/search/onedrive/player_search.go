package onedrive

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

func (d *Onedrive) PlayerSearch(ctx context.Context, dir model.Obj, query, kind, cursor string) ([]model.Obj, string, int64, bool, error) {
	endpoint := d.GetMetaUrl(false, dir.GetPath()) + "/search(q='" + url.PathEscape(strings.ReplaceAll(query, "'", "''")) + "')?$top=48&$select=id,name,size,folder,file,parentReference,fileSystemInfo,lastModifiedDateTime,remoteItem"
	if cursor != "" {
		expected, _ := url.Parse(endpoint)
		next, err := url.Parse(cursor)
		if err != nil || next.Scheme != expected.Scheme || next.Host != expected.Host || next.User != nil || next.Path != expected.Path {
			return nil, "", 0, false, errors.New("invalid search cursor")
		}
		endpoint = cursor
	}
	var resp struct {
		Value []struct {
			ID         string    `json:"id"`
			Name       string    `json:"name"`
			Size       int64     `json:"size"`
			Folder     *struct{} `json:"folder"`
			RemoteItem *struct{} `json:"remoteItem"`
			Modified   time.Time `json:"lastModifiedDateTime"`
			Parent     struct {
				Path string `json:"path"`
			} `json:"parentReference"`
		} `json:"value"`
		Next string `json:"@odata.nextLink"`
	}
	_, err := d.Request(endpoint, http.MethodGet, func(req *resty.Request) { req.SetContext(ctx) }, &resp)
	if err != nil {
		return nil, "", 0, false, err
	}
	if len(resp.Value) > 48 {
		return nil, "", 0, false, errors.New("invalid search page")
	}
	root := strings.TrimRight(d.RootFolderPath, "/")
	objects := make([]model.Obj, 0, len(resp.Value))
	for _, file := range resp.Value {
		if file.RemoteItem != nil {
			continue
		}
		_, parent, ok := strings.Cut(file.Parent.Path, "root:")
		if !ok {
			return nil, "", 0, false, errors.New("missing search parent")
		}
		parent, err = url.PathUnescape(parent)
		if err != nil {
			return nil, "", 0, false, errors.New("invalid search parent")
		}
		full := path.Join("/", parent, file.Name)
		if root != "" && full != root && !strings.HasPrefix(full, root+"/") {
			return nil, "", 0, false, errors.New("search result outside mount")
		}
		objects = append(objects, &model.Object{ID: file.ID, Name: file.Name, Path: strings.TrimPrefix(full, root), Size: file.Size, Modified: file.Modified, IsFolder: file.Folder != nil})
	}
	return objects, resp.Next, -1, false, nil
}
