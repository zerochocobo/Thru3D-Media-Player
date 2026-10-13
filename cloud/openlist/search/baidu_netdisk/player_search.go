package baidu_netdisk

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"net/http"
	"strings"
	"unicode/utf8"
)

func (d *BaiduNetdisk) PlayerSearch(ctx context.Context, dir model.Obj, query, kind, cursor string) ([]model.Obj, string, int64, bool, error) {
	if cursor != "" || utf8.RuneCountInString(query) > 30 {
		return nil, "", 0, false, errors.New("invalid Baidu search request")
	}
	params := map[string]string{"method": "search", "key": query, "dir": dir.GetPath(), "recursion": "1", "num": "500", "web": "0"}
	if kind == "video" {
		params["category"] = "1"
	}
	if kind == "image" {
		params["category"] = "3"
	}
	var resp ListResp
	_, err := d.request("https://pan.baidu.com/rest/2.0/xpan/file", http.MethodGet, func(req *resty.Request) { req.SetContext(ctx).SetQueryParams(params) }, &resp)
	if err != nil {
		return nil, "", 0, false, err
	}
	if len(resp.List) > 500 {
		return nil, "", 0, false, errors.New("invalid Baidu search response")
	}
	root := strings.TrimRight(d.RootFolderPath, "/")
	objects := make([]model.Obj, 0, len(resp.List))
	for _, file := range resp.List {
		obj := fileToObj(file)
		if root != "" && obj.Path != root && !strings.HasPrefix(obj.Path, root+"/") {
			return nil, "", 0, false, errors.New("search result outside mount")
		}
		obj.Path = strings.TrimPrefix(obj.Path, root)
		objects = append(objects, obj)
	}
	// The documented endpoint has a fixed result limit, not a paging cursor.
	return objects, "", int64(len(objects)), len(resp.List) == 500, nil
}
