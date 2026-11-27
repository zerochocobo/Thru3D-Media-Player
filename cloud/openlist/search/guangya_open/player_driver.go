package guangya_open

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/go-resty/resty/v2"
)

// Token-only mount for the GuangYaPan open platform. The platform has no
// delete API, and its write APIs stay unused even when enabled.
type PlayerCredential struct {
	driver.RootID
	ClientID     string `json:"client_id"`
	RefreshToken string `json:"refresh_token"`
}
type PlayerGuangya struct {
	model.Storage
	PlayerCredential
	mu          sync.Mutex
	client      *resty.Client
	accessToken string
	expires     time.Time
	lastCall    map[string]time.Time
}

func init() { op.RegisterDriver(func() driver.Driver { return &PlayerGuangya{} }) }
func (d *PlayerGuangya) Config() driver.Config {
	return driver.Config{Name: "GuangyaPlayer", LocalSort: true}
}
func (d *PlayerGuangya) GetAddition() driver.Additional { return &d.PlayerCredential }
func (d *PlayerGuangya) Init(ctx context.Context) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !clientIDs[d.ClientID] || d.RefreshToken == "" || len(d.RefreshToken) > 16384 || !playerObjectID(d.RootFolderID, true) {
		return errors.New("guangya sign in required")
	}
	d.client = playerClientFactory()
	d.lastCall = map[string]time.Time{}
	return d.renew(ctx)
}
func (d *PlayerGuangya) Drop(context.Context) error { return nil }

func (d *PlayerGuangya) renew(ctx context.Context) error {
	response, err := d.client.R().SetContext(ctx).SetHeader("x-client-id", d.ClientID).
		SetBody(map[string]string{"client_id": d.ClientID, "grant_type": "refresh_token", "refresh_token": d.RefreshToken}).
		Post(accountBase + "/v1/auth/token")
	if err != nil {
		return safeNetworkError(err)
	}
	token, err := parseToken(response)
	if err != nil {
		// A declined refresh needs a new sign-in; an unreadable reply may be a passing outage.
		if reason, declined := strings.CutPrefix(err.Error(), "guangya sign-in declined "); declined {
			return fmt.Errorf("guangya sign in required; refresh declined %s", reason)
		}
		return err
	}
	d.accessToken = token.AccessToken
	lifetime := time.Duration(min(max(token.ExpiresIn, 120), 86400)) * time.Second
	d.expires = time.Now().Add(lifetime - time.Minute)
	if token.RefreshToken != d.RefreshToken {
		d.RefreshToken = token.RefreshToken
		if d.Storage.ID > 0 {
			op.MustSaveDriverStorage(d)
		}
	}
	return nil
}

// Published per-IP limits: listing 5/s, every other read 2/s.
func (d *PlayerGuangya) pace(ctx context.Context, endpoint string) error {
	gap := 510 * time.Millisecond
	if endpoint == "/openapi/v1/file/get_file_list" {
		gap = 210 * time.Millisecond
	}
	if wait := time.Until(d.lastCall[endpoint].Add(gap)); wait > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	d.lastCall[endpoint] = time.Now()
	return nil
}

type apiResponse struct {
	Code int             `json:"code"`
	Msg  string          `json:"msg"`
	Data json.RawMessage `json:"data"`
}

func (d *PlayerGuangya) request(ctx context.Context, endpoint string, query map[string]string, result any) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.client == nil {
		return errors.New("guangya sign in required")
	}
	// A rejected refreshed token must terminate rather than refreshing again.
	for attempt := 0; attempt < 2; attempt++ {
		if time.Now().After(d.expires) {
			if err := d.renew(ctx); err != nil {
				return err
			}
		}
		if err := d.pace(ctx, endpoint); err != nil {
			return err
		}
		var body apiResponse
		response, err := d.client.R().SetContext(ctx).SetQueryParams(query).
			SetHeaders(map[string]string{"x-client-id": d.ClientID, "Authorization": "Bearer " + d.accessToken}).
			Get(apiBase + endpoint)
		if err != nil {
			return safeNetworkError(err)
		}
		if json.Unmarshal(response.Body(), &body) != nil {
			return fmt.Errorf("guangya API unavailable (HTTP %d)", response.StatusCode())
		}
		switch body.Code {
		case 0:
			if json.Unmarshal(body.Data, result) != nil {
				return errors.New("invalid guangya response")
			}
			return nil
		case 117:
			d.expires = time.Time{}
			continue
		case 430, 164:
			return fmt.Errorf("guangya membership required (%d)", body.Code)
		case 146, 149:
			return errors.New("cloud file not found")
		}
		return fmt.Errorf("guangya API declined (%d)", body.Code)
	}
	return errors.New("guangya sign in required; refreshed token rejected (117)")
}

type playerFile struct {
	FileID   string `json:"fileId"`
	FileName string `json:"fileName"`
	FileSize int64  `json:"fileSize"`
	ParentID string `json:"parentId"`
	Depth    int    `json:"depth"`
	ResType  int    `json:"resType"`
	Ctime    int64  `json:"ctime"`
	Utime    int64  `json:"utime"`
}

func (f playerFile) object() *model.Object {
	modified := f.Utime
	if modified == 0 {
		modified = f.Ctime
	}
	return &model.Object{ID: f.FileID, Name: f.FileName, Size: f.FileSize, IsFolder: f.ResType == 2,
		Modified: time.Unix(modified, 0), Ctime: time.Unix(f.Ctime, 0)}
}
func playerObjectID(id string, root bool) bool {
	return (root || id != "") && len(id) <= 256 && !strings.ContainsAny(id, "/\\\x00\r\n")
}
func playerName(name string) bool {
	return name != "" && name != "." && name != ".." && len(name) <= 1024 && !strings.ContainsAny(name, "/\\\x00\r\n")
}

func (d *PlayerGuangya) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	return d.PlayerPageSized(ctx, dir, cursor, order, 48)
}

// Pages are offsets in the platform's page/pageSize scheme.
func (d *PlayerGuangya) PlayerOffsetCursor(offset int) string { return strconv.Itoa(offset) }
func (d *PlayerGuangya) PlayerPageSized(ctx context.Context, dir model.Obj, cursor, order string, size int) ([]model.Obj, string, int64, error) {
	if size < 1 || size > 100 || order != "source" || !playerObjectID(dir.GetID(), true) {
		return nil, "", 0, errors.New("unsupported guangya page")
	}
	offset := 0
	if cursor != "" {
		var err error
		if offset, err = strconv.Atoi(cursor); err != nil || offset < 0 || offset%size != 0 || offset > 1000000 {
			return nil, "", 0, errors.New("invalid guangya cursor")
		}
	}
	query := map[string]string{"page": strconv.Itoa(offset / size), "pageSize": strconv.Itoa(size)}
	if dir.GetID() != "" {
		query["parentId"] = dir.GetID()
	}
	var result struct {
		Total int64        `json:"total"`
		List  []playerFile `json:"list"`
	}
	if err := d.request(ctx, "/openapi/v1/file/get_file_list", query, &result); err != nil {
		return nil, "", 0, err
	}
	if len(result.List) > size || result.Total < 0 {
		return nil, "", 0, errors.New("invalid guangya page")
	}
	rows := make([]model.Obj, 0, len(result.List))
	seen := map[string]bool{}
	for _, file := range result.List {
		if !playerObjectID(file.FileID, false) || seen[file.FileID] {
			return nil, "", 0, errors.New("invalid guangya file identity")
		}
		seen[file.FileID] = true
		// Names the player cannot address as a path segment are left out.
		if playerName(file.FileName) && (file.ResType == 1 || file.ResType == 2) {
			rows = append(rows, file.object())
		}
	}
	next := ""
	if len(result.List) == size && int64(offset+size) < result.Total {
		next = strconv.Itoa(offset + size)
	}
	return rows, next, result.Total, ctx.Err()
}
func (d *PlayerGuangya) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	if remote == "/" {
		return &model.Object{ID: d.RootFolderID, Name: "/", IsFolder: true}, nil
	}
	if id != "" {
		if !playerObjectID(id, false) {
			return nil, errors.New("invalid guangya folder")
		}
		return &model.Object{ID: id, Name: path.Base(remote), Path: remote, IsFolder: true}, nil
	}
	var folder model.Obj = &model.Object{ID: d.RootFolderID, IsFolder: true}
	budget := 200
	for _, name := range strings.Split(strings.TrimPrefix(remote, "/"), "/") {
		var found model.Obj
		for cursor := ""; ; {
			if budget == 0 {
				return nil, errors.New("directory location expired; reopen the cloud account")
			}
			budget--
			rows, next, _, err := d.PlayerPageSized(ctx, folder, cursor, "source", 100)
			if err != nil {
				return nil, err
			}
			for _, row := range rows {
				if row.IsDir() && row.GetName() == name {
					if found != nil {
						return nil, errors.New("ambiguous guangya folder")
					}
					found = row
				}
			}
			if next == "" {
				break
			}
			cursor = next
		}
		if found == nil {
			return nil, errors.New("cloud folder not found")
		}
		folder = found
	}
	return folder, nil
}
func (d *PlayerGuangya) List(ctx context.Context, dir model.Obj, _ model.ListArgs) ([]model.Obj, error) {
	var all []model.Obj
	cursor := ""
	for budget := 0; budget < 200; budget++ {
		rows, next, _, err := d.PlayerPageSized(ctx, dir, cursor, "source", 100)
		if err != nil {
			return nil, err
		}
		all = append(all, rows...)
		if next == "" {
			return all, nil
		}
		cursor = next
	}
	return nil, errors.New("guangya directory scan limit exceeded")
}
func (d *PlayerGuangya) Link(ctx context.Context, file model.Obj, _ model.LinkArgs) (*model.Link, error) {
	if file.IsDir() || !playerObjectID(file.GetID(), false) {
		return nil, errors.New("invalid guangya playback file")
	}
	// The original bytes, not a VOD transcode, keep size and Range offsets stable.
	var result struct {
		SignedURL   string `json:"signedURL"`
		URLDuration int    `json:"urlDuration"`
	}
	if err := d.request(ctx, "/openapi/v1/file/get_res_download_url", map[string]string{"fileId": file.GetID()}, &result); err != nil {
		return nil, err
	}
	target, err := url.Parse(result.SignedURL)
	if err != nil || target.User != nil || target.Host == "" || target.Scheme != "https" {
		return nil, errors.New("invalid guangya file link")
	}
	expiry := time.Duration(min(max(result.URLDuration/2, 60), 1800)) * time.Second
	return &model.Link{URL: result.SignedURL, Expiration: &expiry}, nil
}

// The bound-stream endpoint verifies one ID by its own details. The listed
// depth stands in for walking each parent at the 2/s detail limit.
func (d *PlayerGuangya) PlayerArchiveTarget(ctx context.Context, remote, id string) (model.Obj, *model.Link, error) {
	if remote == "/" || !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") || !playerObjectID(id, false) {
		return nil, nil, errors.New("invalid guangya playback identity")
	}
	var result struct {
		FileInfo playerFile `json:"fileInfo"`
	}
	if err := d.request(ctx, "/openapi/v1/file/get_file_detail", map[string]string{"fileId": id}, &result); err != nil {
		return nil, nil, err
	}
	file := result.FileInfo
	depth := strings.Count(remote, "/")
	if file.FileID != id || file.FileName != path.Base(remote) || file.ResType != 1 || (file.Depth > 0 && d.RootFolderID == "" && file.Depth != depth) {
		return nil, nil, errors.New("guangya playback file moved")
	}
	if file.FileSize <= 0 {
		return nil, nil, errors.New("guangya playback file changed")
	}
	object := file.object()
	if file.Utime == 0 {
		// Details may omit utime; a listed utime must not read as a changed file.
		object.Modified = time.Time{}
	}
	return object, nil, nil
}
