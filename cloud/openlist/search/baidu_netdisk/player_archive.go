package baidu_netdisk

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/go-resty/resty/v2"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"time"
)

func (d *BaiduNetdisk) PlayerArchiveTarget(ctx context.Context, remote, id string) (model.Obj, *model.Link, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if id == "" {
		// Legacy path-only records: one bounded native search, never List or paging.
		dir, err := d.PlayerFolder(ctx, path.Dir(remote), "")
		if err != nil {
			return nil, nil, err
		}
		query := []rune(path.Base(remote))
		if len(query) > 30 {
			query = query[:30]
		}
		files, _, _, _, err := d.PlayerSearch(ctx, dir, string(query), "all", "")
		if err != nil {
			return nil, nil, err
		}
		for _, file := range files {
			if !file.IsDir() && file.GetPath() == remote {
				if id != "" {
					return nil, nil, errors.New("ambiguous archive source")
				}
				id = file.GetID()
			}
		}
	}
	value, err := strconv.ParseInt(id, 10, 64)
	if err != nil || value <= 0 || strconv.FormatInt(value, 10) != id {
		return nil, nil, errors.New("archive location expired; refresh the folder")
	}
	var resp struct {
		List []struct {
			File
			Dlink string `json:"dlink"`
		} `json:"list"`
	}
	_, err = d.request("https://pan.baidu.com/rest/2.0/xpan/multimedia", http.MethodGet, func(r *resty.Request) {
		r.SetContext(ctx).SetQueryParams(map[string]string{"method": "filemetas", "fsids": "[" + id + "]", "dlink": "1"})
	}, &resp)
	if err != nil {
		return nil, nil, err
	}
	if len(resp.List) != 1 {
		return nil, nil, errors.New("archive file missing")
	}
	file := resp.List[0]
	if file.FsId != value || file.Isdir != 0 || file.Path != path.Join("/", d.RootFolderPath, remote) || file.Size <= 0 || file.Dlink == "" {
		return nil, nil, errors.New("archive file missing or replaced")
	}
	link, err := url.Parse(file.Dlink)
	if err != nil || link.Scheme != "https" && link.Scheme != "http" || link.Host == "" {
		return nil, nil, errors.New("invalid download address")
	}
	params := link.Query()
	params.Set("access_token", d.AccessToken)
	link.RawQuery = params.Encode()
	response, err := base.NoRedirectClient.R().SetContext(ctx).SetHeader("User-Agent", "pan.baidu.com").Head(link.String())
	if err != nil {
		return nil, nil, err
	}
	location := response.Header().Get("Location")
	if location == "" {
		return nil, nil, errors.New("download address unavailable")
	}
	lifetime := time.Hour
	return fileToObj(file.File), &model.Link{URL: location, Header: http.Header{"User-Agent": []string{"pan.baidu.com"}}, Expiration: &lifetime}, nil
}
