package _115_open

import (
	"context"
	"errors"
	"path"
	"strconv"
	"strings"

	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

// Playback needs one file's identity, size and pick code. A missing timestamp is
// not a reason to enumerate a directory. Writes keep PlayerVerifyTarget instead.
func (d *Open115) PlayerPlaybackTarget(ctx context.Context, remote, id string) (model.Obj, error) {
	if remote == "/" || !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid playback path")
	}
	if err := d.WaitLimit(ctx); err != nil {
		return nil, err
	}
	var info *sdk.GetFolderInfoResp
	var err error
	if id != "" {
		if len(id) > 128 || id[0] == '0' || strings.Trim(id, "0123456789") != "" {
			return nil, errors.New("invalid playback identity")
		}
		info, err = d.client.GetFolderInfo(ctx, id)
	} else {
		info, err = d.client.GetFolderInfoByPath(ctx, path.Join(d.parentPath, remote))
	}
	if err != nil {
		return nil, err // Never fall back to Get/List or filename search.
	}
	if info.FileID == "" || id != "" && info.FileID != id || info.FileName != path.Base(remote) || info.FileCategory == "0" || info.SizeByte <= 0 || info.PickCode == "" {
		return nil, errors.New("invalid playback object")
	}
	// An ID can have moved since browsing. Verify its authoritative mount-relative
	// path. Path lookup itself is scoped by parentPath; verify returned paths too.
	if id != "" || len(info.Paths) > 0 {
		actual, e := d.playerInfoPath(info)
		if e != nil || actual != remote {
			return nil, errors.New("playback file moved; refresh the folder")
		}
	}
	obj, err := playerLookupObjects(info.FileID, info.FileName, strconv.FormatInt(info.SizeByte, 10), info.FileCategory, info.PickCode, info.UTime)
	if err != nil {
		return nil, err
	}
	parent := len(info.Paths) - 1
	if parent >= 0 && info.Paths[parent].FileID == info.FileID {
		parent--
	}
	if parent >= 0 {
		obj.(*Obj).Pid = info.Paths[parent].FileID
	}
	return obj, nil
}

func (o *Obj) PlayerParentID() string { return o.Pid }
