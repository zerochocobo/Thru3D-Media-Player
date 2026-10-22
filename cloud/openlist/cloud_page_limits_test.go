package cloudcore

import (
	"context"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"strconv"
	"strings"
	"testing"
)

type sizedCursorFixture struct {
	cursorFixture
	sizes []int
}

func (d *sizedCursorFixture) PlayerPageSized(_ context.Context, _ model.Obj, cursor, _ string, size int) ([]model.Obj, string, int64, error) {
	start, _ := strconv.Atoi(cursor)
	d.sizes = append(d.sizes, size)
	objects := make([]model.Obj, size)
	for i := range objects {
		objects[i] = testObj(strconv.Itoa(start+i+1), "movie.mp4", false)
	}
	return objects, strconv.Itoa(start + size), -1, nil
}

type directCursorFixture struct{ sizedCursorFixture }

func (d *directCursorFixture) PlayerOffsetCursor(offset int) string { return strconv.Itoa(offset) }

func TestVariablePageSizesIsolateCursorSessionsAndBoundRows(t *testing.T) {
	resetCursorFixtures(t)
	d := &sizedCursorFixture{}
	read := func(offset, size int) (cursorCloudPage, error) {
		return readCursorDirectory(context.Background(), d, d, "/mount", "/Movies", "folder-id", offset, "name_asc", false, size)
	}
	first, err := read(0, 200)
	if err != nil || len(first.objects) != 200 || first.next != 200 {
		t.Fatal(first, err)
	}
	if _, err := read(100, 100); err != errDirectoryPageExpired {
		t.Fatal("page size reused another session", err)
	}
	if _, err := read(0, 100); err != nil {
		t.Fatal(err)
	}
	for i := 1; i < 40; i++ {
		if _, err := read(i*200, 200); err != nil {
			t.Fatal(err)
		}
	}
	total := 0
	for _, s := range cursorCloudSessions {
		for _, p := range s.pages {
			total += len(p.objects)
		}
	}
	if total > 4096 {
		t.Fatal("unbounded page cache", total)
	}
}

func TestNumericProviderCanJumpWithoutEarlierPages(t *testing.T) {
	resetCursorFixtures(t)
	d := &directCursorFixture{}
	page, err := readCursorDirectory(context.Background(), d, d, "/mount", "/Movies", "folder-id", 527000, "name_asc", false, 1000)
	if err != nil || page.next != 528000 || page.objects[0].GetID() != "527001" || len(d.sizes) != 1 {
		t.Fatal(page.next, err, d.sizes)
	}
}

func TestOversizedMetadataCannotEnterPageCaches(t *testing.T) {
	if err := checkListingMetadata([]model.Obj{testObj("1", strings.Repeat("x", 8193), false)}); err == nil {
		t.Fatal("unbounded metadata accepted")
	}
	if err := checkListingMetadata([]model.Obj{nil}); err == nil {
		t.Fatal("nil object accepted")
	}
}
