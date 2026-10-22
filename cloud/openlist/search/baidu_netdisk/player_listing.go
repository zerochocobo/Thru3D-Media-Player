package baidu_netdisk

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

func (d *BaiduNetdisk) PlayerFolder(_ context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	full := path.Join("/", d.RootFolderPath, remote)
	if id == "" {
		id = full
	}
	return &model.Object{ID: id, Path: full, Name: path.Base(full), IsFolder: true}, nil
}

func (d *BaiduNetdisk) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	return d.PlayerPageSized(ctx, dir, cursor, order, 48)
}

func (d *BaiduNetdisk) PlayerPageSized(ctx context.Context, dir model.Obj, cursor, order string, pageSize int) ([]model.Obj, string, int64, error) {
	if pageSize < 1 || pageSize > 1000 {
		return nil, "", 0, errors.New("invalid directory page size")
	}
	if err := ctx.Err(); err != nil {
		return nil, "", 0, err
	}
	start := int64(0)
	if cursor != "" {
		n, err := strconv.ParseInt(cursor, 10, 64)
		if err != nil || n < 0 || n > 2147483647-int64(pageSize) {
			return nil, "", 0, errors.New("invalid directory cursor")
		}
		start = n
	}
	field, desc := d.OrderBy, d.OrderDirection == "desc"
	switch order {
	case "source":
	case "name_asc", "name_desc":
		field, desc = "name", order == "name_desc"
	case "size_asc", "size_desc":
		field, desc = "size", order == "size_desc"
	case "modified_asc", "modified_desc":
		field, desc = "time", order == "modified_desc"
	default:
		return nil, "", 0, errors.New("invalid directory sort order")
	}
	params := map[string]string{"method": "list", "dir": dir.GetPath(), "start": strconv.FormatInt(start, 10), "limit": strconv.Itoa(pageSize), "order": field, "desc": "0", "web": "web"}
	if desc {
		params["desc"] = "1"
	}
	var resp ListResp
	_, err := d.request("https://pan.baidu.com/rest/2.0/xpan/file", http.MethodGet, func(r *resty.Request) { r.SetContext(ctx).SetQueryParams(params) }, &resp)
	if err != nil {
		return nil, "", 0, err
	}
	if resp.Errno != 0 || len(resp.List) > pageSize {
		return nil, "", 0, errors.New("invalid Baidu directory response")
	}
	objects := make([]model.Obj, 0, len(resp.List))
	for _, file := range resp.List {
		objects = append(objects, fileToObj(file))
	}
	next := start + int64(len(resp.List))
	if len(resp.List) == pageSize {
		return objects, strconv.FormatInt(next, 10), -1, nil
	}
	if len(objects) == 0 && start > 0 {
		return objects, "", -1, nil
	}
	return objects, "", next, nil
}

// Numeric offsets are issued by this provider; no opaque cursor replay is needed.
func (d *BaiduNetdisk) PlayerOffsetCursor(offset int) string { return strconv.Itoa(offset) }
