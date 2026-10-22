package _115_open

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"

	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
)

func listingDriver(transport playerSearchTransport) *Open115 {
	d := &Open115{}
	d.RootFolderID, d.OrderBy, d.OrderDirection = "0", "file_name", "asc"
	d.client = sdk.New(sdk.WithAccessToken("fixture")).SetHttpClient(&http.Client{Transport: transport})
	return d
}

func listingResponse(r *http.Request, body string) *http.Response {
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}
}

func TestPlayerKnownFolderIDListsOnlyFirstBatchWithoutAnyPathSearch(t *testing.T) {
	calls := 0
	d := listingDriver(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != "/open/ufile/files" || r.URL.Query().Get("cid") != "9007199254740993" || r.URL.Query().Get("limit") != "48" {
			t.Fatal("first page performed directory discovery", r.URL)
		}
		return listingResponse(r, `{"state":true,"count":8000,"offset":0,"data":[{"fid":"1","fn":"movie.mp4","fc":"1","fs":12}]}`), nil
	})
	dir, err := d.PlayerFolder(context.Background(), "/电影/3D/合集", "9007199254740993")
	if err != nil || calls != 0 {
		t.Fatal("ID resolution sent a request", err, calls)
	}
	files, total, err := d.PlayerListPage(context.Background(), dir, 0, "name_asc")
	if err != nil || calls != 1 || len(files) != 1 || total != 8000 {
		t.Fatal(err, calls, total)
	}
	for _, id := range []string{"0", "01", "../42", "42/1", "-1", "4a", strings.Repeat("1", 129)} {
		if _, err := d.PlayerFolder(context.Background(), "/Movies", id); err == nil {
			t.Fatal("accepted malformed ID", id)
		}
	}
	if calls != 1 {
		t.Fatal("invalid ID caused fallback search", calls)
	}
	root, err := d.PlayerFolder(context.Background(), "/", "99")
	if err != nil || root.GetID() != "0" || calls != 1 {
		t.Fatal("root used a stale child ID", root, err)
	}
}

func TestPlayerDirectoryPagesNeverEnumerateTheRestForAnyOrder(t *testing.T) {
	orders := map[string][2]string{"source": {"file_name", "1"}, "name_asc": {"file_name", "1"}, "name_desc": {"file_name", "0"},
		"size_asc": {"file_size", "1"}, "size_desc": {"file_size", "0"}, "modified_asc": {"user_utime", "1"}, "modified_desc": {"user_utime", "0"}}
	for _, total := range []int{8000, 50000} {
		for order, expected := range orders {
			t.Run(fmt.Sprintf("%d/%s", total, order), func(t *testing.T) {
				calls := 0
				d := listingDriver(func(r *http.Request) (*http.Response, error) {
					calls++
					q := r.URL.Query()
					offset, _ := strconv.Atoi(q.Get("offset"))
					if q.Get("cid") != "42" || q.Get("limit") != "48" || q.Get("cur") != "1" || q.Get("show_dir") != "1" || q.Get("o") != expected[0] || q.Get("asc") != expected[1] {
						t.Fatal("wrong native page query", q)
					}
					rows := make([]map[string]any, 48)
					for i := range rows {
						rows[i] = map[string]any{"fid": fmt.Sprint(offset + i + 1), "fn": fmt.Sprintf("3D %d.mp4", offset+i), "fc": "1", "fs": 90000000000}
					}
					body, _ := json.Marshal(map[string]any{"state": true, "count": total, "offset": offset, "data": rows})
					return listingResponse(r, string(body)), nil
				})
				for i, offset := range []int64{0, 48} {
					items, count, err := d.PlayerListPage(context.Background(), &model.Object{ID: "42", IsFolder: true}, offset, order)
					if err != nil || len(items) != 48 || count != int64(total) || calls != i+1 || items[0].GetSize() != 90000000000 {
						t.Fatal(err, len(items), count, calls)
					}
				}
			})
		}
	}
}

func TestPlayerGroupingIsExplicitBeforeSelectingEachPage(t *testing.T) {
	for _, mixed := range []bool{false, true} {
		calls := 0
		d := listingDriver(func(r *http.Request) (*http.Response, error) {
			calls++
			q := r.URL.Query()
			mode := "1"
			if mixed {
				mode = "2"
			}
			if q.Get("custom_order") != mode || q.Get("offset") != "200" || q.Get("o") != "user_utime" {
				t.Fatal("grouping was omitted or applied after paging", q)
			}
			return listingResponse(r, `{"state":true,"count":201,"offset":200,"data":[{"fid":"201","fn":"latest.mp4","fc":"1","fs":12}]}`), nil
		})
		order := "modified_desc"
		if mixed {
			order = "mixed_" + order
		}
		items, total, err := d.PlayerListPageSized(context.Background(), &model.Object{ID: "42", IsFolder: true}, 200, order, 200)
		if err != nil || calls != 1 || len(items) != 1 || total != 201 {
			t.Fatal(err, calls, total)
		}
	}
}

func TestPlayerGroupingFollows115CustomOrderAcrossPageBoundary(t *testing.T) {
	// Protocol fixture: custom_order=2 disables folder priority even if fc_mix=0.
	// Deliberately ignore fc_mix, so the previous fixed-mode request fails here.
	grouped := []sdk.GetFilesResp_File{
		{Fid: "2", Fn: "B folder", Fc: "0", Upt: 20},
		{Fid: "4", Fn: "D folder", Fc: "0", Upt: 5},
		{Fid: "1", Fn: "A.mp4", Fc: "1", Upt: 30},
		{Fid: "3", Fn: "C.mp4", Fc: "1", Upt: 10},
	}
	mixed := []sdk.GetFilesResp_File{grouped[2], grouped[0], grouped[3], grouped[1]}
	calls := 0
	d := listingDriver(func(r *http.Request) (*http.Response, error) {
		calls++
		q := r.URL.Query()
		if q.Get("o") != "user_utime" || q.Get("asc") != "0" || q.Get("limit") != "2" || q.Get("show_dir") != "1" || q.Get("cur") != "1" {
			t.Fatal("sorting, page size or folder visibility changed", q)
		}
		rows := grouped
		switch q.Get("custom_order") {
		case "1":
		case "2":
			rows = mixed
		default:
			t.Fatal("request used account memory instead of the directory preference", q)
		}
		offset, err := strconv.Atoi(q.Get("offset"))
		if err != nil || (offset != 0 && offset != 2) {
			t.Fatal("unexpected page offset", q)
		}
		body, _ := json.Marshal(map[string]any{"state": true, "count": 4, "offset": offset, "data": rows[offset : offset+2]})
		return listingResponse(r, string(body)), nil
	})
	dir := &model.Object{ID: "42", IsFolder: true}
	for _, test := range []struct {
		order string
		want  []string
	}{
		{"modified_desc", []string{"B folder", "D folder", "A.mp4", "C.mp4"}},
		{"mixed_modified_desc", []string{"A.mp4", "B folder", "C.mp4", "D folder"}},
	} {
		var names []string
		for _, offset := range []int64{0, 2} {
			items, total, err := d.PlayerListPageSized(context.Background(), dir, offset, test.order, 2)
			if err != nil || total != 4 || len(items) != 2 {
				t.Fatal(test.order, total, err)
			}
			for _, item := range items {
				names = append(names, item.GetName())
			}
		}
		if strings.Join(names, "|") != strings.Join(test.want, "|") {
			t.Fatalf("%s returned %v; want %v", test.order, names, test.want)
		}
	}
	if calls != 4 {
		t.Fatal("grouping caused a directory crawl", calls)
	}
}

func TestPlayerDirectoryRejectsBrokenPagesAndHonorsCancellation(t *testing.T) {
	for _, body := range []string{
		`{"state":true,"count":8000,"offset":0,"data":[]}`,
		`{"state":true,"count":1,"offset":48,"data":[]}`,
		`{"state":true,"count":-1,"offset":0,"data":[]}`,
		`{"state":true,"count":2,"offset":0,"data":[{"fid":"1"},{"fid":"1"}]}`,
		`{"state":false,"code":430004,"message":"fixture rejection"}`,
	} {
		d := listingDriver(func(r *http.Request) (*http.Response, error) { return listingResponse(r, body), nil })
		if _, _, err := d.PlayerListPage(context.Background(), &model.Object{ID: "0", IsFolder: true}, 0, "name_asc"); err == nil {
			t.Fatal("accepted invalid response", body)
		}
	}
	calls := 0
	d := listingDriver(func(r *http.Request) (*http.Response, error) { calls++; return nil, r.Context().Err() })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := d.PlayerListPage(ctx, &model.Object{ID: "0", IsFolder: true}, 0, "name_asc"); err == nil {
		t.Fatal("cancelled page succeeded")
	}
	if _, _, err := d.PlayerListPage(ctx, &model.Object{ID: "0", IsFolder: true}, 0, "unknown"); err == nil {
		t.Fatal("accepted unknown order")
	}
}

func TestPlayerDirectoryShortPagesUseTheActualRowOffset(t *testing.T) {
	calls := 0
	d := listingDriver(func(r *http.Request) (*http.Response, error) {
		calls++
		var body string
		if calls == 1 {
			if r.URL.Query().Get("offset") != "0" {
				t.Fatal(r.URL.Query())
			}
			body = `{"state":true,"count":3,"offset":0,"data":[{"fid":"1","fn":"one.mp4"},{"fid":"2","fn":"two.mp4"}]}`
		} else {
			if r.URL.Query().Get("offset") != "2" {
				t.Fatal(r.URL.Query())
			}
			body = `{"state":true,"count":3,"offset":2,"data":[{"fid":"3","fn":"three.mp4"}]}`
		}
		return listingResponse(r, body), nil
	})
	dir := &model.Object{ID: "0", IsFolder: true}
	first, total, err := d.PlayerListPage(context.Background(), dir, 0, "name_asc")
	if err != nil || total != 3 || len(first) != 2 || calls != 1 {
		t.Fatal(err, total, first, calls)
	}
	last, total, err := d.PlayerListPage(context.Background(), dir, int64(len(first)), "name_asc")
	if err != nil || total != 3 || len(last) != 1 || calls != 2 {
		t.Fatal(err, total, last, calls)
	}
}

func TestPlayerLookupRejectsDuplicateNamesAcrossSearchPagesWithoutListingParents(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		calls := 0
		d := listingDriver(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Path != "/open/ufile/search" {
				t.Fatal("lookup enumerated a directory", r.URL.Path)
			}
			q := r.URL.Query()
			if q.Get("search_value") != "3D合集" || q.Get("cid") != "0" {
				t.Fatal(q)
			}
			rows := make([]map[string]any, 0)
			if q.Get("offset") == "0" {
				for i := 0; i < 48; i++ {
					rows = append(rows, map[string]any{"file_id": fmt.Sprint(i + 1000), "file_name": "3D合集 extra", "file_size": "12", "file_category": "1", "parent_id": "0"})
				}
				rows[0] = map[string]any{"file_id": "42", "file_name": "3D合集", "file_size": "0", "file_category": "0", "parent_id": "0"}
			} else {
				name, parent := "3D合集", "other-folder"
				if duplicate {
					parent = "0"
				}
				rows = append(rows, map[string]any{"file_id": "49", "file_name": name, "file_size": "0", "file_category": "0", "parent_id": parent})
			}
			offset, _ := strconv.Atoi(q.Get("offset"))
			body, _ := json.Marshal(map[string]any{"state": true, "count": 49, "offset": offset, "data": rows})
			return listingResponse(r, string(body)), nil
		})
		obj, err := d.PlayerLookup(context.Background(), "/3D合集")
		if calls != 2 || duplicate && err == nil || !duplicate && (err != nil || obj.GetID() != "42") {
			t.Fatal(calls, err, obj)
		}
	}
}

func TestKnownPlaybackParentSearchesOnlyFilenameAndPreservesPickCode(t *testing.T) {
	calls := 0
	d := listingDriver(func(r *http.Request) (*http.Response, error) {
		calls++
		q := r.URL.Query()
		if r.URL.Path != "/open/ufile/search" || q.Get("cid") != "42" || q.Get("search_value") != "film.mp4" {
			t.Fatal("searched an ancestor", r.URL)
		}
		return listingResponse(r, `{"state":true,"count":3,"offset":0,"data":[{"file_id":"9","file_name":"film.mp4","file_size":"100","file_category":"1","parent_id":"42","pick_code":"pick"},{"file_id":"10","file_name":"film.mp4","file_size":"100","file_category":"1","parent_id":"child"},{"file_id":"11","file_name":"film.mp4","file_size":"100","file_category":"1","parent_id":"42","area_id":"7"}]}`), nil
	})
	obj, err := d.PlayerLookupChild(context.Background(), &model.Object{ID: "42", IsFolder: true}, "film.mp4")
	if err != nil || calls != 1 || obj.GetID() != "9" || obj.(*Obj).Pc != "pick" {
		t.Fatal(obj, err, calls)
	}
}

func TestAuthoritativeWriteObjectRejectsMovedPathsAndPreservesCurrentMetadata(t *testing.T) {
	for _, moved := range []bool{false, true} {
		d := listingDriver(func(r *http.Request) (*http.Response, error) {
			if r.URL.Path != "/open/folder/get_info" || r.URL.Query().Get("file_id") != "9" {
				t.Fatal(r.URL)
			}
			parent := "V"
			if moved {
				parent = "moved"
			}
			return listingResponse(r, fmt.Sprintf(`{"state":true,"data":{"file_id":"9","file_name":"film.mp4","file_category":"1","size_byte":100,"utime":"42","paths":[{"file_id":"0","file_name":""},{"file_id":"42","file_name":"%s"}]}}`, parent)), nil
		})
		obj, err := d.PlayerVerifyTarget(context.Background(), "/V/film.mp4", "9")
		if moved {
			if err == nil {
				t.Fatal("moved object accepted")
			}
		} else if err != nil || obj.GetID() != "9" || obj.GetSize() != 100 || obj.ModTime().Unix() != 42 || obj.(*Obj).Pid != "42" {
			t.Fatal(obj, err)
		}
	}
}

func TestObjectIdentityReadbackNeverTreatsUnknownMetadataAsMissing(t *testing.T) {
	for _, tc := range []struct {
		body            string
		present, failed bool
	}{
		{`{"state":true,"data":{"file_id":"9","file_name":"film.mp4"}}`, true, false},
		{`{"state":true,"data":[]}`, false, false},
		{`{"state":true,"data":{}}`, false, true},
		{`{"state":false,"code":430004,"message":"object not found"}`, false, false},
		{`{"state":false,"code":500000,"message":"fixture rejection"}`, false, true},
	} {
		d := listingDriver(func(r *http.Request) (*http.Response, error) { return listingResponse(r, tc.body), nil })
		present, err := d.PlayerObjectExists(context.Background(), "9")
		if present != tc.present || (err != nil) != tc.failed {
			t.Fatal(tc.body, present, err)
		}
	}
}

func TestVerifiedDeletionSendsOnlySelectedIDAndAuthoritativeParent(t *testing.T) {
	for _, includesSelf := range []bool{false, true} {
		writes := 0
		d := listingDriver(func(r *http.Request) (*http.Response, error) {
			switch r.URL.Path {
			case "/open/folder/get_info":
				self := ""
				if includesSelf {
					self = `,{"file_id":"9","file_name":"film.mp4"}`
				}
				return listingResponse(r, fmt.Sprintf(`{"state":true,"data":{"file_id":"9","file_name":"film.mp4","file_category":"1","size_byte":100,"utime":"42","paths":[{"file_id":"0","file_name":""},{"file_id":"42","file_name":"V"}%s]}}`, self)), nil
			case "/open/ufile/delete":
				writes++
				if err := r.ParseForm(); err != nil || r.Form.Get("file_ids") != "9" || r.Form.Get("parent_id") != "42" {
					t.Fatal("incorrect deletion identity", r.Form, err)
				}
				return listingResponse(r, `{"state":true,"data":["9"]}`), nil
			default:
				t.Fatal("unexpected management request", r.URL.Path)
				return nil, fmt.Errorf("unexpected request")
			}
		})
		obj, err := d.PlayerVerifyTarget(context.Background(), "/V/film.mp4", "9")
		if err != nil {
			t.Fatal(err)
		}
		if err := d.Remove(context.Background(), obj); err != nil || writes != 1 {
			t.Fatal(err, writes)
		}
	}
}
