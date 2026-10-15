package cloudcore

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

type renameFixture struct {
	deletionFixture
	renamed []string
}

func (d *renameFixture) Rename(_ context.Context, obj model.Obj, name string) (model.Obj, error) {
	d.renamed = append(d.renamed, obj.GetID()+":"+name)
	return nil, errors.New("lost response")
}
func TestRenameVerifiesObjectIdAndPreservesFileExtension(t *testing.T) {
	for _, tc := range []struct {
		p, name string
		folder  bool
	}{
		{"/old.MP4", "new.MP4", false}, {"/old.folder", "new.folder", true},
	} {
		d := &renameFixture{deletionFixture: deletionFixture{files: map[string][]model.Obj{"0": {testObj("9", tc.p[1:], tc.folder)}}}}
		err := checkedCloudRename(context.Background(), d, tc.p, cloudTarget{ID: "9", Folder: tc.folder, Size: 12, Modified: 10}, tc.name)
		if err == nil || len(d.renamed) != 1 || d.renamed[0] != "9:"+tc.name {
			t.Fatal(err, d.renamed)
		}
	}
}
func TestRenameRejectsTraversalExtensionChangesCollisionsAndStaleIdentity(t *testing.T) {
	for _, name := range []string{"../new.mp4", "new/m.mp4", "new\\m.mp4", "new.mkv", "new.MP4", "new.mp4 ", "new\x00.mp4", ".new.mp4", ""} {
		d := &renameFixture{deletionFixture: deletionFixture{files: map[string][]model.Obj{"0": {testObj("9", "old.mp4", false)}}}}
		if checkedCloudRename(context.Background(), d, "/old.mp4", cloudTarget{ID: "9", Size: 12, Modified: 10}, name) == nil || len(d.renamed) > 0 {
			t.Fatal(name, d.renamed)
		}
	}
	for _, objects := range [][]model.Obj{
		{testObj("10", "old.mp4", false)},
		{testObj("9", "old.mp4", false), testObj("10", "NEW.mp4", true)},
		{&model.Object{ID: "9", Name: "old.mp4", Size: 12, Mask: model.NoRename}},
	} {
		d := &renameFixture{deletionFixture: deletionFixture{files: map[string][]model.Obj{"0": objects}}}
		if checkedCloudRename(context.Background(), d, "/old.mp4", cloudTarget{ID: "9", Size: 12, Modified: 10}, "new.mp4") == nil || len(d.renamed) > 0 {
			t.Fatal(d.renamed)
		}
	}
}
