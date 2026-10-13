package _115_open

import (
	"context"
	"errors"
	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"path"
	"strconv"
	"time"
)

type playerSearchObject struct {
	model.Object
	parentID string
}

func (o *playerSearchObject) PlayerParentID() string { return o.parentID }

// The adapter uses the driver's existing client, refresh callback and rate limiter.
func (d *Open115) PlayerSearch(ctx context.Context, dir model.Obj, query, kind, cursor string) ([]model.Obj, string, int64, bool, error) {
	offset := int64(0)
	if cursor != "" {
		var err error
		offset, err = strconv.ParseInt(cursor, 10, 64)
		if err != nil || offset < 0 || offset >= 10000 {
			return nil, "", 0, false, errors.New("invalid search cursor")
		}
	}
	req := &sdk.SearchFilesReq{SearchValue: query, CID: dir.GetID(), Limit: min(48, 10000-offset), Offset: offset}
	switch kind {
	case "video":
		req.Type, req.FC = "4", "2"
	case "image":
		req.Type, req.FC = "2", "2"
	case "folder":
		req.FC = "1"
	}
	if err := d.WaitLimit(ctx); err != nil {
		return nil, "", 0, false, err
	}
	resp, err := d.client.SearchFiles(ctx, req)
	if err != nil {
		return nil, "", 0, false, err
	}
	if resp.Offset != offset || len(resp.Data) > 48 || resp.Count < 0 {
		return nil, "", 0, false, errors.New("invalid search response")
	}
	objects := make([]model.Obj, 0, len(resp.Data))
	for _, item := range resp.Data {
		rawSize := item.FileSize
		if rawSize == "" && item.FileCategory == "0" {
			rawSize = "0"
		}
		size, err := strconv.ParseInt(rawSize, 10, 64)
		if err != nil || size < 0 {
			return nil, "", 0, false, errors.New("invalid file size")
		}
		modified, _ := strconv.ParseInt(item.UserUtime, 10, 64)
		objects = append(objects, &playerSearchObject{Object: model.Object{ID: item.FileID, Name: item.FileName, Size: size, IsFolder: item.FileCategory == "0", Modified: time.Unix(modified, 0)}, parentID: item.ParentID})
	}
	next := offset + int64(len(resp.Data))
	capped := next >= 10000 && next < resp.Count
	if next < resp.Count && !capped {
		if len(objects) == 0 {
			return nil, "", 0, false, errors.New("empty intermediate search page")
		}
		return objects, strconv.FormatInt(next, 10), resp.Count, false, nil
	}
	return objects, "", resp.Count, capped, nil
}

// Resolve a selected result only. Never crawl parents to render a search page.
func (d *Open115) PlayerSearchParent(ctx context.Context, parentID string) (string, error) {
	if parentID == d.GetRootId() {
		return "/", nil
	}
	if err := d.WaitLimit(ctx); err != nil {
		return "", err
	}
	info, err := d.client.GetFolderInfo(ctx, parentID)
	if err != nil {
		return "", err
	}
	rootID := d.GetRootId()
	found := rootID == "0"
	result := "/"
	for _, ancestor := range info.Paths {
		if ancestor.FileID == rootID {
			found = true
			result = "/"
			continue
		}
		if !found {
			continue
		}
		if ancestor.FileID == "0" {
			continue
		}
		if !playerSafeName(ancestor.FileName) {
			return "", errors.New("invalid parent name")
		}
		result = path.Join(result, ancestor.FileName)
	}
	if !found || info.FileID != parentID {
		return "", errors.New("search result outside mount")
	}
	// Folder-info paths may include the folder itself or only its ancestors.
	if len(info.Paths) == 0 || info.Paths[len(info.Paths)-1].FileID != parentID {
		if !playerSafeName(info.FileName) {
			return "", errors.New("invalid parent name")
		}
		result = path.Join(result, info.FileName)
	}
	return result, nil
}
func playerSafeName(name string) bool {
	return name != "" && name != "." && name != ".." && path.Base(name) == name && !stringsContainsUnsafe(name)
}
func stringsContainsUnsafe(value string) bool {
	for _, r := range value {
		if r == 0 || r == '\\' || r == '/' {
			return true
		}
	}
	return false
}
