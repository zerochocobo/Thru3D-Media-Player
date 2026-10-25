package cloudcore

import (
	"context"
	"github.com/OpenListTeam/OpenList/v4/drivers/aliyundrive_open"
	"github.com/OpenListTeam/OpenList/v4/drivers/baidu_netdisk"
	"github.com/OpenListTeam/OpenList/v4/drivers/onedrive"
	"github.com/OpenListTeam/OpenList/v4/drivers/quark_open"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"testing"
)

// All four production drivers now provide exact cold recovery. A visible page
// still wins without making any metadata request (including on a cancelled IO client).
func TestPdfDriversSupportColdRecoveryAndReuseVisibleDirectoryIdentity(t *testing.T) {
	for _, d := range []driver.Driver{&baidu_netdisk.BaiduNetdisk{}, &aliyundrive_open.AliyundriveOpen{}, &quark_open.QuarkOpen{}, &onedrive.Onedrive{}} {
		t.Run(d.Config().Name, func(t *testing.T) {
			d.GetStorage().MountPath = "/12345678-1234-1234-1234-123456789cde"
			q := cloudTarget{Mount: d.GetStorage().MountPath, Path: "/Comics/book.pdf"}
			if _, ok := d.(comicSourceReader); !ok {
				t.Fatal("missing exact recovery adapter")
			}
			file := &model.Object{ID: "9007199254740994", Name: "book.pdf", Size: 3145925, Path: q.Path}
			key := q.Mount + "/Comics\x00source"
			previous := cursorCloudSessions[key]
			cursorCloudSessions[key] = &cursorCloudSession{storage: d, pages: map[int]cursorCloudPage{480: {objects: []model.Obj{file}}}}
			defer func() {
				if previous == nil {
					delete(cursorCloudSessions, key)
				} else {
					cursorCloudSessions[key] = previous
				}
			}()
			got, err := comicSourceObject(context.Background(), d, q)
			if err != nil || got != file {
				t.Fatal("visible PDF must retain its actual provider object", err)
			}
		})
	}
}
