package cloudcore

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/gin-gonic/gin"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

type nativeCloudSearcher interface {
	PlayerSearch(context.Context, model.Obj, string, string, string) ([]model.Obj, string, int64, bool, error)
}
type boundedCurrentCloudSearcher interface {
	PlayerSearchCurrent(context.Context, model.Obj, string) ([]model.Obj, bool, error)
}

const cloudSearchResultLimit = 200
const cloudSearchPageLimit = 5

type cloudParentResolver interface {
	PlayerSearchParent(context.Context, string) (string, error)
}
type cloudSearchRequest struct {
	Mount   string `json:"mount"`
	Path    string `json:"path"`
	Query   string `json:"query"`
	Scope   string `json:"scope"`
	Kind    string `json:"kind"`
	Cursor  string `json:"cursor"`
	Refresh bool   `json:"refresh"`
}
type searchPage struct {
	Objects []model.Obj
	Next    string
	Total   int64
	Capped  bool
}
type searchSession struct {
	Request      cloudSearchRequest
	Storage      driver.Driver
	Root         model.Obj
	Expires      time.Time
	Pages        map[int]searchPage
	Objects      map[string]model.Obj
	Paths        map[string]string
	Seen         map[string]bool
	Local        []model.Obj
	NativeCursor string
	Loaded       int
	Scanned      int
	Capped       bool
}

var cloudSearchSessions = map[string]*searchSession{} // Serialized JNI management requests.

func searchRoutes(router *gin.Engine) {
	router.POST("/search", searchCloud)
	router.POST("/searchresolve", resolveCloudSearch)
}
func searchStorage(mount, remote string) (driver.Driver, error) {
	if !cloudMount.MatchString(mount) || !validSearchPath(remote) {
		return nil, errors.New("invalid cloud search path")
	}
	s, actual, err := op.GetStorageAndActualPath(mount + remote)
	if err != nil || s == nil || s.GetStorage().MountPath != mount || s.GetStorage().Disabled || actual != remote {
		return nil, errors.New("cloud account unavailable")
	}
	return s, nil
}
func validSearchPath(value string) bool {
	return strings.HasPrefix(value, "/") && path.Clean(value) == value && !strings.ContainsAny(value, "\x00\\")
}
func safeSearchName(value string) bool {
	return value != "" && value != "." && value != ".." && !strings.ContainsAny(value, "/\\\x00")
}
func sameSearch(a, b cloudSearchRequest) bool {
	return a.Mount == b.Mount && a.Path == b.Path && a.Query == b.Query && a.Scope == b.Scope && a.Kind == b.Kind
}
func searchKey() string {
	var key [16]byte
	if _, err := rand.Read(key[:]); err != nil {
		return ""
	}
	return hex.EncodeToString(key[:])
}
func searchError(c *gin.Context, message string) { c.JSON(200, gin.H{"code": 500, "message": message}) }
func matchesSearch(obj model.Obj, query, kind string) bool {
	if !strings.Contains(strings.ToLower(obj.GetName()), strings.ToLower(query)) {
		return false
	}
	if kind == "folder" {
		return obj.IsDir()
	}
	if obj.IsDir() {
		return kind == "all"
	}
	ext := strings.ToLower(path.Ext(obj.GetName()))
	image := strings.Contains("|.jpg|.jpeg|.png|.webp|.heic|.heif|.tif|.tiff|.hdr|.rgbe|.exr|.avif|.avifs|.apng|.gif|.dng|.cr2|.cr3|.nef|.nrw|.arw|.raf|.rw2|.orf|.pef|.srw|", "|"+ext+"|")
	video := strings.Contains("|.mp4|.mkv|.webm|.mov|.m4v|.avi|.ts|.m2ts|.mpg|.mpeg|.wmv|.flv|", "|"+ext+"|")
	document := ext == ".pdf"
	return kind == "all" && (image || video || document) || kind == "image" && image || kind == "video" && video
}

func searchCloud(c *gin.Context) {
	var req cloudSearchRequest
	if c.ShouldBindJSON(&req) != nil {
		searchError(c, "Invalid search")
		return
	}
	req.Query = strings.TrimSpace(req.Query)
	if req.Query == "" || utf8.RuneCountInString(req.Query) > 128 || strings.ContainsRune(req.Query, 0) ||
		(req.Scope != "current" && req.Scope != "tree" && req.Scope != "all") ||
		(req.Kind != "all" && req.Kind != "video" && req.Kind != "image" && req.Kind != "folder") {
		searchError(c, "Invalid search")
		return
	}
	storage, err := searchStorage(req.Mount, req.Path)
	if err != nil {
		searchError(c, "Cloud account unavailable")
		return
	}
	ctx := c.Request.Context()
	if _, native := storage.(cloudNativeMatches); native && req.Scope == "current" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
	}
	key := ""
	page := 0
	var session *searchSession
	if req.Cursor != "" {
		parts := strings.Split(req.Cursor, ":")
		if len(parts) != 2 || req.Refresh {
			searchError(c, "Search expired. Search again")
			return
		}
		key = parts[0]
		page, err = strconv.Atoi(parts[1])
		session = cloudSearchSessions[key]
		if err != nil || page < 0 || session == nil || time.Now().After(session.Expires) || !sameSearch(session.Request, req) || session.Storage != storage {
			searchError(c, "Search expired. Search again")
			return
		}
	} else {
		for id, cached := range cloudSearchSessions {
			if time.Now().After(cached.Expires) {
				delete(cloudSearchSessions, id)
			}
		}
		if len(cloudSearchSessions) >= 4 {
			var oldest string
			var expires time.Time
			for id, cached := range cloudSearchSessions {
				if oldest == "" || cached.Expires.Before(expires) {
					oldest, expires = id, cached.Expires
				}
			}
			delete(cloudSearchSessions, oldest)
		}
		key = searchKey()
		if key == "" {
			searchError(c, "Cloud search unavailable")
			return
		}
		rootPath := req.Path
		if req.Scope == "all" {
			rootPath = "/"
		}
		var root model.Obj
		var e error
		if native, ok := storage.(cloudNativeMatches); ok && req.Scope == "current" {
			root, e = freshMatchParent(ctx, native, req.Mount, rootPath, "")
		} else {
			root, e = op.Get(ctx, storage, rootPath)
		}
		if e != nil || !root.IsDir() {
			searchError(c, "Cloud folder unavailable")
			return
		}
		session = &searchSession{Request: req, Storage: storage, Root: root, Expires: time.Now().Add(5 * time.Minute), Pages: map[int]searchPage{}, Objects: map[string]model.Obj{}, Paths: map[string]string{}, Seen: map[string]bool{}}
		if req.Scope == "current" {
			var objects []model.Obj
			if bounded, ok := storage.(boundedCurrentCloudSearcher); ok {
				objects, session.Capped, err = bounded.PlayerSearchCurrent(ctx, root, req.Query)
			} else if native, ok := storage.(cloudNativeMatches); ok {
				objects, err = native.PlayerMatches(ctx, root, req.Query)
			} else if req.Refresh && storage.Config().Name == "115 Open" {
				objects, err = freshCloudList(c.Request.Context(), storage, req.Path)
			} else {
				objects, err = op.List(c.Request.Context(), storage, req.Path, model.ListArgs{Refresh: req.Refresh})
			}
			if err != nil {
				cloudListError(c, "search.current", err)
				return
			}
			if len(objects) > 20000 {
				searchError(c, "Folder too large to search")
				return
			}
			session.Local = make([]model.Obj, 0)
			for _, obj := range objects {
				if matchesSearch(obj, req.Query, req.Kind) {
					session.Local = append(session.Local, obj)
				}
			}
			sort.SliceStable(session.Local, func(i, j int) bool {
				a, b := session.Local[i], session.Local[j]
				if a.IsDir() != b.IsDir() {
					return a.IsDir()
				}
				return strings.ToLower(a.GetName()) < strings.ToLower(b.GetName())
			})
			if len(session.Local) > cloudSearchResultLimit {
				session.Local = session.Local[:cloudSearchResultLimit]
				session.Capped = true
			}
		} else if _, ok := storage.(nativeCloudSearcher); !ok || (req.Scope == "tree" && storage.Config().Name == "115 Open") {
			searchError(c, "Search scope unavailable")
			return
		}
		cloudSearchSessions[key] = session
	}
	cached, ok := session.Pages[page]
	if !ok {
		if page != session.Loaded || page >= cloudSearchPageLimit {
			searchError(c, "Search result limit reached")
			return
		}
		if req.Scope == "current" {
			start := page * 48
			if start > len(session.Local) {
				searchError(c, "Invalid search page")
				return
			}
			end := min(start+48, len(session.Local))
			cached = searchPage{Objects: session.Local[start:end], Total: int64(len(session.Local)), Capped: session.Capped}
			if end < len(session.Local) {
				cached.Next = key + ":" + strconv.Itoa(page+1)
			}
		} else {
			if page > 0 && session.NativeCursor == "" {
				searchError(c, "Invalid search page")
				return
			}
			raw, next, total, capped, e := storage.(nativeCloudSearcher).PlayerSearch(c.Request.Context(), session.Root, req.Query, req.Kind, session.NativeCursor)
			if e != nil {
				cloudListError(c, "search.native", e)
				return
			}
			if next != "" && next == session.NativeCursor {
				searchError(c, "Repeated search page")
				return
			}
			remaining := cloudSearchResultLimit - session.Scanned
			if len(raw) > remaining {
				raw = raw[:remaining]
				capped = true
			}
			session.Scanned += len(raw)
			if next != "" && (session.Scanned >= cloudSearchResultLimit || page >= cloudSearchPageLimit-1) {
				capped = true
			}
			if capped {
				next = ""
			}
			cached = searchPage{Objects: make([]model.Obj, 0), Total: total, Capped: capped}
			pendingIDs := map[string]bool{}
			for _, obj := range raw {
				if !safeSearchName(obj.GetName()) || obj.GetID() == "" {
					searchError(c, "Invalid search result")
					return
				}
				remote := obj.GetPath()
				if remote != "" && (!validSearchPath(remote) || path.Base(remote) != obj.GetName() || (req.Scope == "tree" && req.Path != "/" && !strings.HasPrefix(remote, req.Path+"/"))) {
					searchError(c, "Invalid search result")
					return
				}
				identity := obj.GetID()
				if session.Seen[identity] || pendingIDs[identity] {
					continue
				}
				pendingIDs[identity] = true
				if matchesSearch(obj, req.Query, req.Kind) {
					cached.Objects = append(cached.Objects, obj)
				}
			}
			for id := range pendingIDs {
				session.Seen[id] = true
			}
			// Baidu returns one bounded 500-result response; subsequent UI pages are local.
			if len(cached.Objects) > 48 {
				session.Local = cached.Objects
				for start := 0; start < len(session.Local); start += 48 {
					end := min(start+48, len(session.Local))
					chunk := searchPage{Objects: session.Local[start:end], Total: total, Capped: capped}
					if end < len(session.Local) {
						chunk.Next = key + ":" + strconv.Itoa(start/48+1)
					}
					session.Pages[start/48] = chunk
				}
				cached = session.Pages[0]
				session.Loaded = len(session.Pages)
			}
			session.NativeCursor = next
			if next != "" {
				if page == cloudSearchPageLimit-1 {
					cached.Capped = true
				} else {
					cached.Next = key + ":" + strconv.Itoa(page+1)
				}
			}
		}
		session.Pages[page] = cached
		session.Loaded = max(session.Loaded, page+1)
	}
	content := make([]gin.H, 0, len(cached.Objects))
	for i, obj := range cached.Objects {
		token := key + ":" + strconv.Itoa(page*48+i)
		session.Objects[token] = obj
		remote := obj.GetPath()
		if req.Scope == "current" {
			remote = path.Join(req.Path, obj.GetName())
		}
		if remote != "" && !validSearchPath(remote) {
			searchError(c, "Invalid search path")
			return
		}
		if remote != "" {
			session.Paths[token] = remote
		}
		content = append(content, gin.H{"name": obj.GetName(), "is_dir": obj.IsDir(), "size": obj.GetSize(), "modified_ms": cloudModified(obj), "id": obj.GetID(), "path": remote, "token": token})
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"content": content, "cursor": req.Cursor, "next_cursor": cached.Next, "total": cached.Total, "limited": cached.Capped, "session": key}})
}

func resolveCloudSearch(c *gin.Context) {
	var req struct {
		Mount string `json:"mount"`
		Token string `json:"token"`
	}
	if c.ShouldBindJSON(&req) != nil {
		searchError(c, "Invalid search result")
		return
	}
	key, _, ok := strings.Cut(req.Token, ":")
	session := cloudSearchSessions[key]
	if !ok || session == nil || session.Request.Mount != req.Mount || time.Now().After(session.Expires) {
		searchError(c, "Search expired. Search again")
		return
	}
	storage, err := searchStorage(req.Mount, session.Request.Path)
	if err != nil || storage != session.Storage {
		searchError(c, "Cloud account unavailable")
		return
	}
	obj := session.Objects[req.Token]
	if obj == nil {
		searchError(c, "Invalid search result")
		return
	}
	remote := session.Paths[req.Token]
	if remote == "" {
		resolver, has := storage.(cloudParentResolver)
		parent, hasParent := obj.(interface{ PlayerParentID() string })
		if !has || !hasParent {
			searchError(c, "Search path unavailable")
			return
		}
		folder, e := resolver.PlayerSearchParent(c.Request.Context(), parent.PlayerParentID())
		if e != nil || !validSearchPath(folder) {
			searchError(c, "Search path unavailable")
			return
		}
		remote = path.Join(folder, obj.GetName())
	}
	if !validSearchPath(remote) {
		searchError(c, "Invalid search path")
		return
	}
	// Preserve path ambiguity handling in normal browsing/playback; search never grants deletion.
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"path": remote, "name": obj.GetName(), "is_dir": obj.IsDir(), "size": obj.GetSize(), "id": obj.GetID()}})
}
