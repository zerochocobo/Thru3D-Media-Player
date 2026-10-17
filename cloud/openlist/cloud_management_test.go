package cloudcore

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

type managementFixture struct {
	deletionFixture
	actual            string
	queries           []string
	parents, verified int
	queryErr          error
	verifyErr         error
	authoritative     model.Obj
}

func (d *managementFixture) PlayerFolder(_ context.Context, _ string, id string) (model.Obj, error) {
	if id == "" {
		panic("known parent ID was discarded")
	}
	return testObj(id, "sub", true), nil
}
func (d *managementFixture) PlayerLookup(context.Context, string) (model.Obj, error) {
	panic("must not search short ancestor names")
}
func (d *managementFixture) PlayerListPage(context.Context, model.Obj, int64, string) ([]model.Obj, int64, error) {
	panic("must not collect directory pages")
}
func (d *managementFixture) PlayerSearchParent(context.Context, string) (string, error) {
	d.parents++
	return d.actual, nil
}
func (d *managementFixture) PlayerMatches(_ context.Context, folder model.Obj, query string) ([]model.Obj, error) {
	d.queries = append(d.queries, query)
	if d.queryErr != nil {
		return nil, d.queryErr
	}
	var result []model.Obj
	for _, obj := range d.files[folder.GetID()] {
		if strings.Contains(strings.ToLower(obj.GetName()), strings.ToLower(query)) {
			result = append(result, obj)
		}
	}
	return result, nil
}
func (d *managementFixture) PlayerLookupChild(ctx context.Context, dir model.Obj, name string) (model.Obj, error) {
	rows, err := d.PlayerMatches(ctx, dir, name)
	if err != nil {
		return nil, err
	}
	var found model.Obj
	for _, obj := range rows {
		if obj.GetName() == name {
			if found != nil {
				return nil, errors.New("ambiguous cloud file")
			}
			found = obj
		}
	}
	if found == nil {
		return nil, errors.New("missing")
	}
	return found, nil
}
func (d *managementFixture) PlayerVerifyTarget(_ context.Context, _ string, id string) (model.Obj, error) {
	d.verified++
	if d.verifyErr != nil {
		return nil, d.verifyErr
	}
	if d.authoritative != nil {
		return d.authoritative, nil
	}
	for _, obj := range d.files["42"] {
		if obj.GetID() == id {
			return obj, nil
		}
	}
	return nil, errors.New("missing")
}

func TestNativeDeletionNeverRemovesSameNameOutsideVerifiedParent(t *testing.T) {
	for _, targetPresent := range []bool{false, true} {
		d := managementDriver()
		d.files["88"] = []model.Obj{testObj("99", "film.mp4", false), testObj("100", "film.mp4", true)}
		if !targetPresent {
			d.files["42"] = nil
		}
		err := checkedCloudRemove(context.Background(), d, d.actual+"/film.mp4", cloudTarget{ID: "9", Size: 12, Modified: 10, FolderID: "42"})
		if targetPresent {
			if err != nil || len(d.writes) != 1 || d.writes[0] != "9" {
				t.Fatal(err, d.writes)
			}
		} else if err == nil || len(d.writes) != 0 {
			t.Fatal("deleted an object from another parent", err, d.writes)
		}
	}
}

func TestNativeDeletionRejectsChangedIdentityMetadataAndFailedReads(t *testing.T) {
	for _, kind := range []string{"moved parent", "moved file", "replacement", "changed ID", "changed name", "changed size", "changed time", "changed kind", "locked", "network", "cancelled"} {
		t.Run(kind, func(t *testing.T) {
			d := managementDriver()
			ctx := context.Background()
			obj := &model.Object{ID: "9", Name: "film.mp4", Size: 12, Modified: time.UnixMilli(10)}
			switch kind {
			case "moved parent":
				d.actual = "/moved"
			case "moved file":
				d.verifyErr = errors.New("authoritative file path changed")
			case "replacement":
				d.files["42"] = []model.Obj{testObj("99", "film.mp4", false)}
			case "changed ID":
				obj.ID = "99"
			case "changed name":
				obj.Name = "other.mp4"
			case "changed size":
				obj.Size++
			case "changed time":
				obj.Modified = time.UnixMilli(11)
			case "changed kind":
				obj.IsFolder = true
			case "locked":
				obj.Mask = model.NoRemove
			case "network":
				d.queryErr = errors.New("timeout")
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			if kind != "replacement" {
				d.authoritative = obj
			}
			err := checkedCloudRemove(ctx, d, "/MOVIE/V/sub/film.mp4", cloudTarget{ID: "9", Size: 12, Modified: 10, FolderID: "42"})
			if err == nil || len(d.writes) != 0 || len(d.reads) != 0 {
				t.Fatal(kind, err, d.writes, d.reads)
			}
		})
	}
}
func (d *managementFixture) Rename(_ context.Context, obj model.Obj, name string) (model.Obj, error) {
	d.writes = append(d.writes, obj.GetID()+":"+name)
	return obj, nil
}
func managementDriver() *managementFixture {
	d := &managementFixture{actual: "/MOVIE/V/sub"}
	d.MountPath = "/12345678-1234-1234-1234-123456789abc"
	d.files = map[string][]model.Obj{"42": {testObj("9", "film.mp4", false), testObj("10", "unrelated.mp4", false)}}
	return d
}
func TestPlaybackKnownOrCachedParentNeverSearchesMOVIEOrV(t *testing.T) {
	cloudFolders = map[string]cloudFolder{}
	t.Cleanup(func() { cloudFolders = map[string]cloudFolder{} })
	d := managementDriver()
	obj, mode, err := lookupCloudFile(context.Background(), d, d.MountPath, d.actual+"/film.mp4", "42")
	if err != nil || obj.GetID() != "9" || mode != "provided_id" || len(d.queries) != 1 || d.parents != 0 {
		t.Fatal(obj, mode, err, d.queries, d.parents)
	}
	cloudFolders[d.MountPath+d.actual] = cloudFolder{object: testObj("42", "sub", true), expires: time.Now().Add(time.Minute)}
	_, mode, err = lookupCloudFile(context.Background(), d, d.MountPath, d.actual+"/film.mp4", "")
	if err != nil || mode != "memory" || len(d.queries) != 2 {
		t.Fatal(mode, err, d.queries)
	}
}
func TestNativeRemoveAndRenameVerifyRealParentAndObjectWithoutDirectoryEnumeration(t *testing.T) {
	for _, rename := range []bool{false, true} {
		d := managementDriver()
		target := cloudTarget{ID: "9", Size: 12, Modified: 10, FolderID: "42"}
		var err error
		if rename {
			err = checkedCloudRename(context.Background(), d, d.actual+"/film.mp4", target, "new.mp4")
		} else {
			err = checkedCloudRemove(context.Background(), d, d.actual+"/film.mp4", target)
		}
		if err != nil || len(d.writes) != 1 || d.parents != 1 || d.verified != 1 || len(d.reads) != 0 {
			t.Fatal(rename, err, d.writes, d.parents, d.verified, d.reads)
		}
		if len(d.queries) != map[bool]int{false: 1, true: 2}[rename] {
			t.Fatal(d.queries)
		}
	}
}
func TestNativeManagementRefusesMovedParentsStaleMetadataCollisionsAndFailedReads(t *testing.T) {
	for _, kind := range []string{"moved parent", "changed size", "changed ID", "collision", "network", "cancelled"} {
		t.Run(kind, func(t *testing.T) {
			d := managementDriver()
			ctx := context.Background()
			switch kind {
			case "moved parent":
				d.actual = "/moved"
			case "changed size":
				d.authoritative = &model.Object{ID: "9", Name: "film.mp4", Size: 13, Modified: time.UnixMilli(10)}
			case "changed ID":
				d.authoritative = testObj("99", "film.mp4", false)
			case "collision":
				d.files["42"] = append(d.files["42"], testObj("11", "NEW.mp4", true))
			case "network":
				d.queryErr = errors.New("timeout")
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			err := checkedCloudRename(ctx, d, "/MOVIE/V/sub/film.mp4", cloudTarget{ID: "9", Size: 12, Modified: 10, FolderID: "42"}, "new.mp4")
			if err == nil || len(d.writes) != 0 || len(d.reads) != 0 {
				t.Fatal(kind, err, d.writes, d.reads)
			}
		})
	}
}

func TestNativeDuplicateNamesKeepSelectedRenameIdentityAndRefuseAmbiguousDeletion(t *testing.T) {
	d := managementDriver()
	d.files["42"] = append(d.files["42"], testObj("11", "film.mp4", false))
	target := cloudTarget{ID: "9", Size: 12, Modified: 10, FolderID: "42"}
	if err := checkedCloudRemove(context.Background(), d, d.actual+"/film.mp4", target); err == nil || len(d.writes) != 0 {
		t.Fatal(err, d.writes)
	}
	if err := checkedCloudRename(context.Background(), d, d.actual+"/film.mp4", target, "new.mp4"); err != nil || len(d.writes) != 1 || d.writes[0] != "9:new.mp4" {
		t.Fatal(err, d.writes)
	}
}
