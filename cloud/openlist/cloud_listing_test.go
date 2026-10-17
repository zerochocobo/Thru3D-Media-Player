package cloudcore

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

type pagingFixture struct {
	deletionFixture
	pages, lookups int
	fail           bool
	listedIDs      []string
}

func (d *pagingFixture) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if id == "" {
		return d.PlayerLookup(ctx, remote)
	}
	return testObj(id, "3D合集", true), nil
}

func (d *pagingFixture) PlayerLookup(context.Context, string) (model.Obj, error) {
	d.lookups++
	return testObj("42", "3D合集", true), nil
}
func (d *pagingFixture) PlayerListPage(_ context.Context, folder model.Obj, offset int64, order string) ([]model.Obj, int64, error) {
	d.pages++
	d.listedIDs = append(d.listedIDs, folder.GetID())
	if d.fail {
		return nil, 0, errors.New("fixture page failed")
	}
	items := make([]model.Obj, 48)
	for i := range items {
		items[i] = testObj(fmt.Sprint(offset+int64(i)+1), fmt.Sprintf("%s-%d.mp4", order, offset+int64(i)), false)
	}
	return items, 50000, nil
}
func TestNativeDirectoryPageCacheSeparatesOrdersAndRefreshesOnlyOnDemand(t *testing.T) {
	cloudSnapshots, cloudFolders = map[string]cloudSnapshot{}, map[string]cloudFolder{}
	t.Cleanup(func() { cloudSnapshots, cloudFolders = map[string]cloudSnapshot{}, map[string]cloudFolder{} })
	d := &pagingFixture{}
	mount := "/12345678-1234-1234-1234-123456789abc"
	read := func(offset int, order string, refresh bool) cloudSnapshot {
		snapshot, err := readCloudListing(context.Background(), d, mount, "/3D合集", offset, order, refresh, "")
		if err != nil || snapshot.total != 50000 || len(snapshot.objects) != 48 {
			t.Fatal(err, snapshot)
		}
		return snapshot
	}
	read(0, "name_asc", false)
	if d.pages != 1 || d.lookups != 1 || len(d.reads) != 0 {
		t.Fatal("first page enumerated directory or parent", d)
	}
	read(0, "name_asc", false)
	read(48, "name_asc", false)
	if d.pages != 2 || d.lookups != 1 {
		t.Fatal("cached page or folder was reread", d)
	}
	read(0, "size_desc", false)
	if d.pages != 3 {
		t.Fatal("sort reused a different order", d.pages)
	}
	d.fail = true
	if _, err := readCloudListing(context.Background(), d, mount, "/3D合集", 96, "name_asc", false, ""); err == nil {
		t.Fatal("page failure ignored")
	}
	read(0, "name_asc", false)
	d.fail = false
	read(96, "name_asc", false)
	if d.pages != 5 {
		t.Fatal("failed page was cached or old page discarded", d.pages)
	}
	read(0, "name_asc", true)
	read(48, "name_asc", false)
	if d.pages != 7 || d.lookups != 2 || len(d.reads) != 0 {
		t.Fatal("refresh retained stale order pages", d)
	}
}

func Test115ColdFolderIDSkipsPathSearchAfterRestartRefreshAndSort(t *testing.T) {
	cloudSnapshots, cloudFolders = map[string]cloudSnapshot{}, map[string]cloudFolder{}
	t.Cleanup(func() { cloudSnapshots, cloudFolders = map[string]cloudSnapshot{}, map[string]cloudFolder{} })
	d := &pagingFixture{}
	read := func(offset int, order string, refresh bool, id string) cloudSnapshot {
		p, err := readCloudListing(context.Background(), d, "/mount", "/电影/3D/合集", offset, order, refresh, id)
		if err != nil || p.total != 50000 || len(p.objects) != 48 {
			t.Fatal(err, p)
		}
		return p
	}
	if p := read(0, "name_asc", false, "42"); d.pages != 1 || d.lookups != 0 || p.resolution != "provided_id" || p.cacheHit {
		t.Fatal("cold first page performed name lookup", d, p)
	}
	if p := read(0, "name_asc", false, "42"); !p.cacheHit || p.resolveMs != 0 || p.listMs != 0 || d.pages != 1 {
		t.Fatal(p, d.pages)
	}
	read(48, "name_asc", false, "42")
	read(0, "size_desc", false, "42")
	read(0, "name_asc", true, "42")
	if d.pages != 4 || d.lookups != 0 {
		t.Fatal("paging, sort or refresh resolved names", d)
	}
	// Process restart loses every page and folder cache; the saved ID remains enough.
	cloudSnapshots, cloudFolders = map[string]cloudSnapshot{}, map[string]cloudFolder{}
	read(0, "name_asc", false, "42")
	if d.pages != 5 || d.lookups != 0 {
		t.Fatal("restart required path search", d)
	}
	// Same-name folders must not share pages when the user selected another ID.
	read(0, "name_asc", false, "99")
	if d.pages != 6 || d.listedIDs[5] != "99" {
		t.Fatal("different folder ID reused cached rows", d)
	}
	read(0, "name_asc", false, "42")
	if d.pages != 7 || d.listedIDs[6] != "42" {
		t.Fatal("folder cache retained a different ID", d)
	}
}
