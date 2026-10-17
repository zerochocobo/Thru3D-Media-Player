package _115_open

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"testing"
)

func TestPlaybackIdentityAndExactPathNeverSearchOrEnumerateMissingTimes(t *testing.T) {
	for _, id := range []string{"9", ""} {
		for _, timestamp := range []string{"", "0", "1700000000"} {
			calls := 0
			d := listingDriver(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Path != "/open/folder/get_info" {
					t.Fatal("playback enumerated/searched", r.URL.Path)
				}
				if id == "9" && r.URL.Query().Get("file_id") != "9" {
					t.Fatal(r.URL)
				}
				if id == "" {
					r.ParseForm()
					if r.Form.Get("path") != "/V/film.mp4" {
						t.Fatal(r.Form)
					}
				}
				return listingResponse(r, fmt.Sprintf(`{"state":true,"data":{"file_id":"9","file_name":"film.mp4","file_category":"1","size_byte":100,"pick_code":"pick","utime":"%s","paths":[{"file_id":"0","file_name":""},{"file_id":"42","file_name":"V"}]}}`, timestamp)), nil
			})
			obj, err := d.PlayerPlaybackTarget(context.Background(), "/V/film.mp4", id)
			if err != nil || obj.GetID() != "9" || obj.(*Obj).Pc != "pick" || calls != 1 {
				t.Fatal(obj, err, calls)
			}
		}
	}
}

func TestPlaybackDoesNotFallBackWhenIdentityMovedMissingOrMetadataFails(t *testing.T) {
	for _, kind := range []string{"moved", "changed id", "folder", "empty pick", "transport", "outside mount"} {
		t.Run(kind, func(t *testing.T) {
			calls := 0
			d := listingDriver(func(r *http.Request) (*http.Response, error) {
				calls++
				if calls > 1 || r.URL.Path != "/open/folder/get_info" {
					t.Fatal("unexpected fallback", r.URL)
				}
				if kind == "transport" {
					return nil, errors.New("fixture timeout")
				}
				id, parent, category, pick := "9", "V", "1", "pick"
				if kind == "moved" {
					parent = "other"
				}
				if kind == "changed id" {
					id = "99"
				}
				if kind == "folder" {
					category = "0"
				}
				if kind == "empty pick" {
					pick = ""
				}
				return listingResponse(r, fmt.Sprintf(`{"state":true,"data":{"file_id":"%s","file_name":"film.mp4","file_category":"%s","size_byte":100,"pick_code":"%s","paths":[{"file_id":"0","file_name":""},{"file_id":"42","file_name":"%s"}]}}`, id, category, pick, parent)), nil
			})
			if kind == "outside mount" {
				d.RootFolderID = "777"
			}
			if _, err := d.PlayerPlaybackTarget(context.Background(), "/V/film.mp4", "9"); err == nil || calls != 1 {
				t.Fatal(err, calls)
			}
		})
	}
}
