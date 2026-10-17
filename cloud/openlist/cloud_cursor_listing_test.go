package cloudcore

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

type cursorFixture struct {
	deletionFixture
	calls, folders int
	fail           bool
	seen           []string
	dropped        bool
}

func (d *cursorFixture) PlayerDropPages() { d.dropped = true }

func (d *cursorFixture) PlayerFolder(_ context.Context, remote, id string) (model.Obj, error) {
	d.folders++
	if id == "" {
		id = "folder-id"
	}
	return &model.Object{ID: id, Name: remote, IsFolder: true}, nil
}
func (d *cursorFixture) PlayerPage(_ context.Context, _ model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	d.calls++
	d.seen = append(d.seen, cursor)
	if d.fail {
		return nil, "", 0, errors.New("fixture failed")
	}
	n := 0
	if cursor != "" {
		n, _ = strconv.Atoi(cursor)
	}
	// Short and even empty provider batches are valid when their cursor advances.
	if n == 1 {
		return nil, "2", -1, nil
	}
	return []model.Obj{testObj(fmt.Sprint(n+1), order+".mp4", false)}, strconv.Itoa(n + 1), -1, nil
}
func resetCursorFixtures(t *testing.T) {
	t.Helper()
	cursorCloudSessions = map[string]*cursorCloudSession{}
	t.Cleanup(func() { cursorCloudSessions = map[string]*cursorCloudSession{} })
}

func TestCursorDirectoryOnlyFetchesRequestedBatchAndRetainsFailedPageForRetry(t *testing.T) {
	resetCursorFixtures(t)
	d := &cursorFixture{}
	ctx := context.Background()
	read := func(offset int, order string, refresh bool) (cursorCloudPage, error) {
		return readCursorDirectory(ctx, d, d, "/mount", "/Movies", "folder-id", offset, order, refresh)
	}
	first, err := read(0, "name_asc", false)
	if err != nil || len(first.objects) != 1 || first.next != 48 || first.total != -1 || d.calls != 1 {
		t.Fatal(first, err, d.calls)
	}
	second, err := read(48, "name_asc", false)
	if err != nil || len(second.objects) != 0 || second.next != 96 || d.calls != 2 || d.seen[1] != "1" {
		t.Fatal(second, err, d.seen)
	}
	d.fail = true
	if _, err = read(96, "name_asc", false); err == nil {
		t.Fatal("failure ignored")
	}
	read(0, "name_asc", false)
	if d.calls != 3 {
		t.Fatal("failure discarded successful pages")
	}
	d.fail = false
	read(96, "name_asc", false)
	if d.calls != 4 || d.seen[3] != "2" {
		t.Fatal("retry changed cursor", d.seen)
	}
	read(0, "modified_desc", false)
	if d.calls != 5 || d.seen[4] != "" {
		t.Fatal("sort reused prior cursor")
	}
	read(48, "name_asc", true)
	if d.calls != 6 || d.seen[5] != "1" {
		t.Fatal("refresh replayed earlier pages", d.seen)
	}
}

func TestExpiredDirectoryCursorDoesNotReplayEveryEarlierNetworkPage(t *testing.T) {
	resetCursorFixtures(t)
	d := &cursorFixture{}
	ctx := context.Background()
	readCursorDirectory(ctx, d, d, "/mount", "/Movies", "folder-id", 0, "name_asc", false)
	cursorCloudSessions["/mount/Movies\x00name_asc"].expires = time.Now().Add(-time.Second)
	_, err := readCursorDirectory(ctx, d, d, "/mount", "/Movies", "folder-id", 48, "name_asc", false)
	if !errors.Is(err, errDirectoryPageExpired) || d.calls != 1 {
		t.Fatal("expired cursor caused replay", err, d.calls)
	}
	_, err = readCursorDirectory(ctx, d, d, "/mount", "/Movies", "folder-id", 0, "name_asc", true)
	if err != nil || d.calls != 2 {
		t.Fatal(err, d.calls)
	}
}

func TestExpiredCachedPageRefetchesItsCursorAndInvalidatesLaterPages(t *testing.T) {
	resetCursorFixtures(t)
	d := &cursorFixture{}
	read := func(offset int) (cursorCloudPage, error) {
		return readCursorDirectory(context.Background(), d, d, "/mount", "/Movies", "folder-id", offset, "name_asc", false)
	}
	for _, offset := range []int{0, 48, 96} {
		if _, err := read(offset); err != nil {
			t.Fatal(err)
		}
	}
	s := cursorCloudSessions["/mount/Movies\x00name_asc"]
	page := s.pages[48]
	page.expires = time.Now().Add(-time.Second)
	s.pages[48] = page
	d.fail = true
	if _, err := read(48); err == nil || len(s.pages) != 3 {
		t.Fatal("failed refetch destroyed visited pages", err)
	}
	d.fail = false
	if _, err := read(48); err != nil || d.calls != 5 || d.seen[4] != "1" {
		t.Fatal("expired page replayed earlier network pages", err, d.seen)
	}
	if _, ok := s.pages[96]; ok {
		t.Fatal("refreshed batch retained a stale following page")
	}
	if _, err := read(96); err != nil || d.calls != 6 || d.seen[5] != "2" {
		t.Fatal("refreshed continuation unavailable", err, d.seen)
	}
	delete(s.pages, 48)
	if _, err := read(48); err != nil || d.calls != 7 {
		t.Fatal("evicted page failed to reload", err)
	}
	if _, ok := s.pages[96]; ok {
		t.Fatal("reloaded evicted page retained an older continuation chain")
	}
}

func TestCursorCacheRemainsBoundedWhilePagingPastFiftyThousandEntries(t *testing.T) {
	resetCursorFixtures(t)
	d := &cursorFixture{}
	for i := 0; i < 1100; i++ {
		p, err := readCursorDirectory(context.Background(), d, d, "/mount", "/Movies", "folder-id", i*48, "name_asc", false)
		if err != nil || p.next != (i+1)*48 {
			t.Fatal(i, p, err)
		}
	}
	s := cursorCloudSessions["/mount/Movies\x00name_asc"]
	if d.calls != 1100 || len(s.pages) > 16 || len(s.cursors) > 65 {
		t.Fatal(d.calls, len(s.pages), len(s.cursors))
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := readCursorDirectory(ctx, d, d, "/mount", "/Movies", "folder-id", 1100*48, "name_asc", false)
	if err == nil {
		t.Fatal("cancelled response committed")
	}
	if _, ok := s.cursors[1101*48]; ok {
		t.Fatal("cancelled page published a continuation")
	}
}

func TestDisconnectDropsDirectorySessionsAndProviderSnapshots(t *testing.T) {
	resetCursorFixtures(t)
	d := &cursorFixture{}
	d.Storage.ID = 7
	readCursorDirectory(context.Background(), d, d, "/mount", "/Movies", "folder-id", 0, "name_asc", false)
	dropCursorStorage(7)
	if len(cursorCloudSessions) != 0 || !d.dropped {
		t.Fatal("disconnected account retained directory sessions")
	}
}
