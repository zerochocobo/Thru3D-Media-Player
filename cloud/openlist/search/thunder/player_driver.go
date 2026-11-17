package thunder

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/go-resty/resty/v2"
)

// Separate driver name keeps the player's token-only mount and bounded retry
// policy independent from the upstream administrator/password workflows.
type PlayerThunder struct {
	*XunLeiCommon
	model.Storage
	PlayerCredential
	mu             sync.Mutex
	requestContext context.Context
}

func init() { op.RegisterDriver(func() driver.Driver { return &PlayerThunder{} }) }
func (d *PlayerThunder) Config() driver.Config {
	return driver.Config{Name: "ThunderPlayer", LocalSort: true}
}
func (d *PlayerThunder) GetAddition() driver.Additional { return &d.PlayerCredential }
func (d *PlayerThunder) Init(ctx context.Context) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !playerEnabled.Load() {
		return errors.New("thunder mount unavailable")
	}
	device, err := hex.DecodeString(d.PlayerCredential.DeviceID)
	if err != nil || len(device) != 16 || d.PlayerCredential.RefreshToken == "" || len(d.PlayerCredential.RefreshToken) > 16384 {
		return errors.New("thunder sign in required")
	}
	d.XunLeiCommon = playerCommon(nil, d.PlayerCredential.DeviceID, d.PlayerCredential.CaptchaToken)
	d.Common.client.OnBeforeRequest(func(_ *resty.Client, r *resty.Request) error {
		r.SetContext(d.requestContext)
		return d.requestContext.Err()
	})
	d.requestContext = ctx
	return d.renew()
}
func (d *PlayerThunder) Drop(context.Context) error { return nil }
func (d *PlayerThunder) save() {
	if d.Storage.ID > 0 {
		op.MustSaveDriverStorage(d)
	}
}
func (d *PlayerThunder) renew() error {
	token, err := d.XunLeiCommon.RefreshToken(d.PlayerCredential.RefreshToken)
	if err != nil {
		return playerSafeError(err)
	}
	if token == nil || token.AccessToken == "" || token.RefreshToken == "" {
		return errors.New("thunder sign in required")
	}
	d.SetTokenResp(token)
	d.PlayerCredential.RefreshToken = token.RefreshToken
	d.save()
	return nil
}
func (d *PlayerThunder) request(ctx context.Context, endpoint string, callback base.ReqCallback, result any) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !playerEnabled.Load() || d.XunLeiCommon == nil || d.TokenResp == nil {
		return errors.New("thunder sign in required")
	}
	d.requestContext = ctx
	// A rejected refreshed token must terminate rather than recursively refreshing.
	for attempt := 0; attempt < 3; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		_, err := d.Common.Request(endpoint, http.MethodGet, func(r *resty.Request) {
			r.SetContext(ctx).SetHeaders(map[string]string{"Authorization": d.Token(), "X-Captcha-Token": d.GetCaptchaToken()})
			if callback != nil {
				callback(r)
			}
		}, result)
		if err == nil {
			return nil
		}
		var response *ErrResp
		if attempt == 2 || !errors.As(err, &response) {
			return playerSafeError(err)
		}
		switch response.ErrorCode {
		case 4122, 4121, 10, 16:
			if err = d.renew(); err != nil {
				return err
			}
		case 9:
			if err = d.RefreshCaptchaTokenAtLogin(GetAction(http.MethodGet, endpoint), d.TokenResp.UserID); err != nil {
				return playerSafeError(err)
			}
			d.PlayerCredential.CaptchaToken = d.GetCaptchaToken()
			d.save()
		default:
			return playerSafeError(err)
		}
	}
	return errors.New("thunder retry limit exceeded")
}
func (d *PlayerThunder) PlayerPage(ctx context.Context, dir model.Obj, cursor, order string) ([]model.Obj, string, int64, error) {
	return d.PlayerPageSized(ctx, dir, cursor, order, 48)
}

type playerCursor struct {
	Token  string `json:"t"`
	Offset int    `json:"o"`
	Hash   string `json:"h,omitempty"`
}

func playerCursorText(value playerCursor) string {
	raw, _ := json.Marshal(value)
	return base64.RawURLEncoding.EncodeToString(raw)
}
func (d *PlayerThunder) PlayerPageSized(ctx context.Context, dir model.Obj, cursor, order string, size int) ([]model.Obj, string, int64, error) {
	if size < 1 || size > 100 || order != "source" || len(cursor) > 16384 || !playerObjectID(dir.GetID(), true) {
		return nil, "", 0, errors.New("unsupported thunder page")
	}
	var position playerCursor
	if cursor != "" {
		raw, err := base64.RawURLEncoding.DecodeString(cursor)
		if err != nil || json.Unmarshal(raw, &position) != nil || len(position.Token) > 8192 || position.Offset < 0 || position.Offset >= 100 ||
			(position.Offset > 0 && len(position.Hash) != 64) {
			return nil, "", 0, errors.New("invalid thunder cursor")
		}
	}
	var result FileList
	err := d.request(ctx, FILE_API_URL, func(r *resty.Request) {
		r.SetQueryParams(map[string]string{
			// The live API can return more rows than a small requested limit.
			// Read a bounded native batch and split it without dropping rows.
			"parent_id": dir.GetID(), "page_token": position.Token, "limit": "100", "space": "", "__type": "drive", "refresh": "true", "__sync": "true", "with_audit": "true",
			"filters": `{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}`,
		})
	}, &result)
	if err != nil {
		return nil, "", 0, err
	}
	if len(result.Files) > 100 || len(result.NextPageToken) > 8192 || result.NextPageToken != "" && result.NextPageToken == position.Token {
		return nil, "", 0, errors.New("invalid thunder page")
	}
	rows := make([]model.Obj, 0, len(result.Files))
	seen := map[string]bool{}
	fingerprint := sha256.New()
	for i := range result.Files {
		file := &result.Files[i]
		if !playerObjectID(file.ID, false) || seen[file.ID] {
			return nil, "", 0, errors.New("invalid thunder file identity")
		}
		seen[file.ID] = true
		if !file.Trashed {
			rows = append(rows, file)
			json.NewEncoder(fingerprint).Encode([]string{file.ID, file.Name, file.Kind})
		}
	}
	hash := hex.EncodeToString(fingerprint.Sum(nil))
	if position.Offset > 0 && (position.Hash != hash || position.Offset >= len(rows)) {
		return nil, "", 0, errors.New("directory page expired; refresh the folder")
	}
	end := min(position.Offset+size, len(rows))
	next := ""
	if end < len(rows) {
		next = playerCursorText(playerCursor{Token: position.Token, Offset: end, Hash: hash})
	} else if result.NextPageToken != "" {
		next = playerCursorText(playerCursor{Token: result.NextPageToken})
	}
	return rows[position.Offset:end], next, -1, ctx.Err()
}
func playerObjectID(id string, root bool) bool {
	return (root || id != "") && len(id) <= 2048 && !strings.ContainsAny(id, "/\\\x00\r\n")
}
func (d *PlayerThunder) PlayerFolder(ctx context.Context, remote, id string) (model.Obj, error) {
	if !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") {
		return nil, errors.New("invalid directory path")
	}
	if remote == "/" {
		return &model.Object{ID: d.RootFolderID, Name: "/", IsFolder: true}, nil
	}
	if id != "" {
		if !playerObjectID(id, false) {
			return nil, errors.New("invalid thunder folder")
		}
		return &model.Object{ID: id, Name: path.Base(remote), Path: remote, IsFolder: true}, nil
	}
	var folder model.Obj = &model.Object{ID: d.RootFolderID, IsFolder: true}
	budget := 200
	for _, name := range strings.Split(strings.TrimPrefix(remote, "/"), "/") {
		cursor := ""
		seen := map[string]bool{}
		var found model.Obj
		for {
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
						return nil, errors.New("ambiguous thunder folder")
					}
					found = row
				}
			}
			if next == "" {
				break
			}
			if seen[next] {
				return nil, errors.New("directory cursor cycle")
			}
			seen[next] = true
			cursor = next
		}
		if found == nil {
			return nil, errors.New("cloud folder not found")
		}
		folder = found
	}
	return folder, nil
}
func (d *PlayerThunder) List(ctx context.Context, dir model.Obj, _ model.ListArgs) ([]model.Obj, error) {
	var all []model.Obj
	cursor := ""
	seen := map[string]bool{}
	for budget := 0; budget < 200; budget++ {
		rows, next, _, err := d.PlayerPageSized(ctx, dir, cursor, "source", 100)
		if err != nil {
			return nil, err
		}
		all = append(all, rows...)
		if next == "" {
			return all, nil
		}
		if seen[next] {
			return nil, errors.New("directory cursor cycle")
		}
		seen[next] = true
		cursor = next
	}
	return nil, errors.New("thunder directory scan limit exceeded")
}
func (d *PlayerThunder) Link(ctx context.Context, file model.Obj, _ model.LinkArgs) (*model.Link, error) {
	if file.IsDir() || !playerObjectID(file.GetID(), false) {
		return nil, errors.New("invalid thunder playback file")
	}
	var result Files
	if err := d.request(ctx, FILE_API_URL+"/"+url.PathEscape(file.GetID()), func(r *resty.Request) {
		r.SetQueryParam("space", d.Space)
		// Request a playback URL: omitting usage can issue a throttled download
		// URL even for the same authorized original file.
		if playerStreamFile(file.GetName()) {
			r.SetQueryParam("usage", "PLAY")
		}
	}, &result); err != nil {
		return nil, err
	}
	if result.ID != file.GetID() || result.Trashed || result.WebContentLink == "" {
		return nil, errors.New("thunder original file unavailable")
	}
	target, err := url.Parse(result.WebContentLink)
	if err != nil || target.User != nil || target.Host == "" || (target.Scheme != "https" && target.Scheme != "http") {
		return nil, errors.New("invalid thunder file link")
	}
	expiry := time.Minute
	// Keep the original bytes/size. Medias may be transcoded files and must not
	// replace this URL under an existing file-bound Range lease.
	return &model.Link{URL: result.WebContentLink, Header: http.Header{"User-Agent": {d.DownloadUserAgent}}, Expiration: &expiry}, nil
}

func playerStreamFile(name string) bool {
	// Match player video/audio extensions; disc images and document/archive
	// reads retain their original download request semantics.
	switch strings.ToLower(path.Ext(name)) {
	case ".mp4", ".mkv", ".mk3d", ".mov", ".m4v", ".webm", ".ts", ".m2ts", ".avi", ".wmv", ".flv", ".mpg", ".mpeg", ".vob",
		".mp3", ".m4a", ".ogg", ".wav", ".flac", ".dts", ".dtshd":
		return true
	}
	return false
}

// The shared bound-stream endpoint also serves ordinary video. Cold playback
// verifies one ID and its parent chain; it never enumerates whole directories.
func (d *PlayerThunder) PlayerArchiveTarget(ctx context.Context, remote, id string) (model.Obj, *model.Link, error) {
	if remote == "/" || !strings.HasPrefix(remote, "/") || path.Clean(remote) != remote || strings.ContainsAny(remote, "\x00\\") || !playerObjectID(id, false) {
		return nil, nil, errors.New("invalid thunder playback identity")
	}
	names := strings.Split(strings.TrimPrefix(remote, "/"), "/")
	if len(names) > 64 {
		return nil, nil, errors.New("thunder path is too deep")
	}
	current := id
	var selected *Files
	for i := len(names) - 1; i >= 0; i-- {
		if !playerObjectID(current, false) || current == d.RootFolderID {
			return nil, nil, errors.New("thunder playback file moved")
		}
		var object Files
		if err := d.request(ctx, FILE_API_URL+"/"+url.PathEscape(current), func(r *resty.Request) { r.SetQueryParam("space", d.Space) }, &object); err != nil {
			return nil, nil, err
		}
		if object.ID != current || object.Name != names[i] || object.Trashed || object.IsDir() != (i < len(names)-1) {
			return nil, nil, errors.New("thunder playback file moved")
		}
		if selected == nil {
			selected = &object
		}
		current = object.ParentID
	}
	if current != d.RootFolderID || selected.GetSize() <= 0 {
		return nil, nil, errors.New("thunder playback file changed")
	}
	return selected, nil, nil
}
