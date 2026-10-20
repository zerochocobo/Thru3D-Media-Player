package cloudcore

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

type companionObject struct {
	model.Object
	parent string
}

func (o *companionObject) PlayerParentID() string { return o.parent }

type companionSearch func(context.Context, model.Obj, string, string, string) ([]model.Obj, string, int64, bool, error)

func (s companionSearch) PlayerSearch(ctx context.Context, dir model.Obj, query, kind, cursor string) ([]model.Obj, string, int64, bool, error) {
	return s(ctx, dir, query, kind, cursor)
}

func TestCompanionsSearchOnlyRequestedFolderAndMatchingNamesAcrossSearchPages(t *testing.T) {
	count := 0
	obj := func(id, name, parent string) model.Obj {
		return &companionObject{Object: model.Object{ID: id, Name: name, Size: 100}, parent: parent}
	}
	search := companionSearch(func(_ context.Context, folder model.Obj, query, kind, cursor string) ([]model.Obj, string, int64, bool, error) {
		count++
		if folder.GetID() != "42" || query != "电影.part1" || kind != "all" {
			t.Fatal("wrong native search scope", folder, query, kind)
		}
		if cursor == "" {
			return []model.Obj{obj("1", "电影.part1.srt", "42"), obj("2", "电影.part1.en.srt", "child"),
				obj("3", "电影.part10.srt", "42"), obj("4", "电影.part1.txt", "42"),
				obj("6", "电影.part1.future_sidecar", "42")}, "4", 6, false, nil
		}
		if cursor != "4" {
			t.Fatal("wrong search continuation", cursor)
		}
		return []model.Obj{obj("5", "电影.part1.si.mix.m4a", "42")}, "", 6, false, nil
	})
	files, err := readCloudCompanions(context.Background(), search, &model.Object{ID: "42", IsFolder: true}, "电影.part1.mp4")
	if err != nil || len(files) != 4 || files[0].GetID() != "1" || files[1].GetID() != "4" ||
		files[2].GetID() != "6" || files[3].GetID() != "5" || count != 2 {
		t.Fatal("companion filter or pagination failed", files, err, count)
	}
}

func TestCompanionSearchCancellationCapsFailuresAndRepeatedCursors(t *testing.T) {
	folder := &model.Object{ID: "42", IsFolder: true}
	for _, failure := range []string{"capped", "repeated", "network"} {
		t.Run(failure, func(t *testing.T) {
			search := companionSearch(func(_ context.Context, _ model.Obj, _, _, cursor string) ([]model.Obj, string, int64, bool, error) {
				switch failure {
				case "capped":
					return nil, "", 10001, true, nil
				case "network":
					return nil, "", 0, false, errors.New("fixture failure")
				default:
					return nil, "same", 100, false, nil
				}
			})
			if _, err := readCloudCompanions(context.Background(), search, folder, "film.mp4"); err == nil {
				t.Fatal("invalid or partial search accepted")
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	search := companionSearch(func(context.Context, model.Obj, string, string, string) ([]model.Obj, string, int64, bool, error) {
		t.Fatal("cancelled search reached provider")
		return nil, "", 0, false, nil
	})
	if _, err := readCloudCompanions(ctx, search, folder, "film.mp4"); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
