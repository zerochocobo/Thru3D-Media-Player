package onedrive

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
)

func (d *Onedrive) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	full := path.Join("/", d.RootFolderPath, remote)
	if id == "" || strings.ContainsAny(id, "/\\\x00") {
		var metadata struct {
			ID     string    `json:"id"`
			Folder *struct{} `json:"folder"`
		}
		_, err := d.Request(d.GetMetaUrl(false, full)+"?$select=id,folder", http.MethodGet, func(r *resty.Request) { r.SetContext(ctx) }, &metadata)
		if err != nil {
			return nil, err
		}
		if metadata.ID == "" || metadata.Folder == nil {
			return nil, errors.New("cloud folder not found")
		}
		id = metadata.ID
	}
	return &model.Object{ID: id, Path: full, Name: path.Base(full), IsFolder: true}, nil
}

func (d *Onedrive) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	field, direction := "", "asc"
	switch order {
	case "source":
	case "name_asc", "name_desc":
		field = "name"
	case "size_asc", "size_desc":
		field = "size"
	case "modified_asc", "modified_desc":
		field = "lastModifiedDateTime"
	default:
		return nil, "", 0, errors.New("invalid directory sort order")
	}
	if strings.HasSuffix(order, "desc") {
		direction = "desc"
	}
	baseURL := strings.TrimSuffix(d.GetMetaUrl(false, "/"), "/root") + "/items/" + url.PathEscape(dir.GetID()) + "/children"
	query := url.Values{"$top": {"48"}, "$select": {"id,name,size,folder,file,lastModifiedDateTime,fileSystemInfo"}}
	if field != "" {
		query.Set("$orderby", field+" "+direction)
	}
	endpoint := baseURL + "?" + query.Encode()
	if cursor != "" {
		expected, _ := url.Parse(baseURL)
		next, err := url.Parse(cursor)
		canonical := next != nil && strings.HasPrefix(next.Path, "/v1.0/drives/") && strings.HasSuffix(next.Path, "/items/"+dir.GetID()+"/children")
		if err != nil || next.Scheme != expected.Scheme || next.Host != expected.Host || next.User != nil || next.Fragment != "" || next.Path != expected.Path && !canonical {
			return nil, "", 0, errors.New("invalid directory cursor")
		}
		endpoint = cursor
	}
	var resp struct {
		Value []struct {
			ID       string               `json:"id"`
			Name     string               `json:"name"`
			Size     int64                `json:"size"`
			Folder   *struct{}            `json:"folder"`
			Modified time.Time            `json:"lastModifiedDateTime"`
			FSI      *FileSystemInfoFacet `json:"fileSystemInfo"`
		} `json:"value"`
		Next string `json:"@odata.nextLink"`
	}
	_, err := d.Request(endpoint, http.MethodGet, func(r *resty.Request) { r.SetContext(ctx) }, &resp)
	if err != nil {
		return nil, "", 0, err
	}
	if len(resp.Value) > 48 {
		return nil, "", 0, errors.New("invalid directory page")
	}
	objects := make([]model.Obj, 0, len(resp.Value))
	for _, file := range resp.Value {
		modified := file.Modified
		if modified.IsZero() && file.FSI != nil {
			modified = file.FSI.LastModifiedDateTime
		}
		objects = append(objects, &model.Object{ID: file.ID, Name: file.Name, Size: file.Size, Path: path.Join(dir.GetPath(), file.Name), IsFolder: file.Folder != nil, Modified: modified})
	}
	return objects, resp.Next, -1, nil
}
