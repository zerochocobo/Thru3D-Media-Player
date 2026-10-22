package cloudcore

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

type sizedCloudDriver interface {
	PlayerListPageSized(context.Context, model.Obj, int64, string, int) ([]model.Obj, int64, error)
}
type sizedCursorCloudDriver interface {
	PlayerPageSized(context.Context, model.Obj, string, string, int) ([]model.Obj, string, int64, error)
}
type offsetCloudDriver interface{ PlayerOffsetCursor(int) string }

// Legacy companion/queue readers retain their 48-row contracts.
func listingPageSize(requested []int) int {
	if len(requested) == 0 || requested[0] == 0 {
		return 48
	}
	return requested[0]
}
func checkListingMetadata(objects []model.Obj) error {
	size := 0
	for _, obj := range objects {
		if obj == nil {
			return errors.New("invalid directory object")
		}
		row := len(obj.GetName()) + len(obj.GetID()) + len(obj.GetPath())
		if row > 8192 {
			return errors.New("directory metadata limit exceeded")
		}
		size += row + 256
	}
	if size > 2*1024*1024 {
		return errors.New("directory metadata limit exceeded")
	}
	return nil
}
func snapshotRows() int {
	total := 0
	for _, page := range cloudSnapshots {
		total += len(page.objects)
	}
	return total
}

// Bound cached rows globally, including sessions with different page sizes.
func trimDirectoryRows() {
	total := 0
	for _, session := range cursorCloudSessions {
		for _, page := range session.pages {
			total += len(page.objects)
		}
	}
	for total > 4096 {
		var selected *cursorCloudSession
		key := 0
		var oldest cursorCloudPage
		for _, session := range cursorCloudSessions {
			for offset, page := range session.pages {
				if selected == nil || page.expires.Before(oldest.expires) {
					selected, key, oldest = session, offset, page
				}
			}
		}
		if selected == nil {
			break
		}
		delete(selected.pages, key)
		total -= len(oldest.objects)
	}
}
