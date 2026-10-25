package _115_open

import (
	"context"
	"fmt"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"net/http"
	"testing"
)

func TestPdfExactPathOrListedIDKeepsPickCodeAndUsesOriginalDownload(t *testing.T) {
	for _, id := range []string{"", "9007199254740994"} {
		t.Run("id_"+id, func(t *testing.T) {
			metadata, downloads := 0, 0
			name := "漫画 #?%.PDF"
			d := listingDriver(func(r *http.Request) (*http.Response, error) {
				switch r.URL.Path {
				case "/open/folder/get_info":
					metadata++
					if id == "" {
						r.ParseForm()
						if r.Form.Get("path") != "/V/"+name {
							t.Fatal("PDF path changed")
						}
					} else if r.URL.Query().Get("file_id") != id {
						t.Fatal("PDF ID changed")
					}
					return listingResponse(r, fmt.Sprintf(`{"state":true,"data":{"file_id":"9007199254740994","file_name":%q,"file_category":"1","size_byte":3145925,"pick_code":"pdf-pick","paths":[{"file_id":"0","file_name":""},{"file_id":"42","file_name":"V"}]}}`, name)), nil
				case "/open/ufile/downurl":
					downloads++
					r.ParseForm()
					if r.Form.Get("pick_code") != "pdf-pick" || r.Header.Get("User-Agent") != "pdf-reader-fixture" {
						t.Fatal("PDF ticket binding changed")
					}
					return listingResponse(r, `{"state":true,"data":{"9007199254740994":{"file_size":3145925,"url":{"url":"https://cdnfhnfile.115cdn.net/original.pdf?ticket=fixture"}}}}`), nil
				default:
					return nil, fmt.Errorf("PDF unexpectedly called %s", r.URL.Path)
				}
			})
			obj, err := d.PlayerPlaybackTarget(context.Background(), "/V/"+name, id)
			if err != nil {
				t.Fatal(err)
			}
			link, err := d.Link(context.Background(), obj, model.LinkArgs{Header: http.Header{"User-Agent": []string{"pdf-reader-fixture"}}})
			if err != nil {
				t.Fatal(err)
			}
			if metadata != 1 || downloads != 1 || link.URL != "https://cdnfhnfile.115cdn.net/original.pdf?ticket=fixture" || link.Header.Get("User-Agent") != "pdf-reader-fixture" {
				t.Fatal("PDF original-file resolution changed", metadata, downloads)
			}
		})
	}
}
