package cloudcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/OpenListTeam/OpenList/v4/server/common"
	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
)

// Only operations for the same account serialize. A restored mount is loaded by
// its first caller, under that caller's deadline. Keep only the row ID at rest.
type mountRequests struct {
	gate     chan struct{}
	number   uint64
	provider string
	pending  atomic.Uint32
	holder   atomic.Uint64
}

var mounts = struct {
	sync.Mutex
	next  uint64
	items map[string]*mountRequests
}{items: make(map[string]*mountRequests)}

func mountQueue(path, provider string) *mountRequests {
	mounts.Lock()
	defer mounts.Unlock()
	if q := mounts.items[path]; q != nil {
		return q
	}
	mounts.next++
	q := &mountRequests{gate: make(chan struct{}, 1), number: mounts.next, provider: driverLabel(provider)}
	mounts.items[path] = q
	return q
}
func knownMount(path string) *mountRequests {
	mounts.Lock()
	defer mounts.Unlock()
	return mounts.items[path]
}
func restoreMounts() error {
	rows, err := db.GetEnabledStorages()
	if err != nil {
		return err
	}
	for _, row := range rows {
		mountQueue(row.MountPath, row.Driver).pending.Store(uint32(row.ID))
	}
	return nil
}
func (q *mountRequests) load(ctx context.Context, tr *cloudOperation) error {
	id := q.pending.Load()
	if id == 0 {
		return nil
	}
	row, err := db.GetStorageById(uint(id))
	if err != nil {
		return err
	}
	tr.record("init_start")
	err = op.LoadStorage(ctx, *row)
	if err != nil && ctx.Err() != nil {
		tr.record("init_cancelled")
		return ctx.Err()
	}
	if err != nil {
		// A temporary Init failure must not poison this mount for the rest of the process.
		tr.record("init_error")
		return errors.New("cloud account initialization failed: " + cloudDiagnosticText(err.Error()))
	}
	q.pending.Store(0)
	tr.record("init_ready")
	return nil
}
func firstMount(path string) string {
	segment, _, _ := strings.Cut(strings.TrimPrefix(path, "/"), "/")
	if segment == "" {
		return ""
	}
	return "/" + segment
}
func requestMount(route, body string) (string, *mountRequests) {
	path, query, _ := strings.Cut(route, "?")
	var target struct {
		Mount, Path, Driver string
		MountPath           string `json:"mount_path"`
	}
	switch path {
	case "/comic", "/drivers", "/accounts", "/thunder-auth", "/guangya-auth":
		return "", nil
	case "/delete", "/account":
		if api == nil {
			return "", nil
		}
		params, _ := url.ParseQuery(query)
		id, err := strconv.ParseUint(params.Get("id"), 10, 32)
		if err != nil {
			return "", nil
		}
		row, err := db.GetStorageById(uint(id))
		if err != nil {
			return "", nil
		}
		return row.MountPath, knownMount(row.MountPath)
	}
	if json.Unmarshal([]byte(body), &target) != nil {
		return "", nil
	}
	switch path {
	case "/create":
		if target.MountPath != "" {
			return target.MountPath, mountQueue(target.MountPath, target.Driver)
		}
	case "/update":
		var update struct{ ID uint }
		if api != nil && json.Unmarshal([]byte(body), &update) == nil {
			if row, e := db.GetStorageById(update.ID); e == nil {
				return row.MountPath, knownMount(row.MountPath)
			}
		}
	case "/list":
		target.Mount = firstMount(target.Path)
	}
	return target.Mount, knownMount(target.Mount)
}
func (q *mountRequests) forget(path string) {
	mounts.Lock()
	defer mounts.Unlock()
	if mounts.items[path] == q {
		delete(mounts.items, path)
	}
}

// The legacy stream endpoint can be the first operation after process restart.
// The mount gate protects only initialization, never the subsequent byte stream.
func readyStreamMount(c *gin.Context) {
	q := knownMount(firstMount(c.Param("path")))
	if q == nil || q.pending.Load() == 0 {
		c.Next()
		return
	}
	ctx := c.Request.Context()
	select {
	case q.gate <- struct{}{}:
	case <-ctx.Done():
		c.Abort()
		return
	}
	err := func() error { defer func() { <-q.gate }(); return q.load(ctx, nil) }()
	if err != nil {
		c.AbortWithStatus(http.StatusServiceUnavailable)
		return
	}
	c.Next()
}

// Upstream JWTs for the same user in the same second are identical.
var tokens = struct {
	sync.Mutex
	refs map[string]int
}{refs: make(map[string]int)}

func acquireToken() (string, error) {
	tokens.Lock()
	defer tokens.Unlock()
	token, err := common.GenerateToken(admin)
	if err == nil {
		tokens.refs[token]++
	}
	return token, err
}
func releaseToken(token string) {
	tokens.Lock()
	defer tokens.Unlock()
	tokens.refs[token]--
	if tokens.refs[token] == 0 {
		delete(tokens.refs, token)
		common.InvalidateToken(token)
	}
}

type cloudOperation struct {
	id     uint64
	owner  string
	caller int64
	start  time.Time
	// The operation is bound before dispatch and immutable while its driver runs.
	mount *mountRequests
	op    string
}
type operationKey struct{}

var requestNumber atomic.Uint64

// RequestLogSink forwards the same allow-listed events to the Android process log.
type RequestLogSink interface{ Record(line string) }

func SetRequestLogSink(sink RequestLogSink) {
	cloudTrace.Lock()
	defer cloudTrace.Unlock()
	cloudTrace.sink = sink
}

var cloudTrace = struct {
	sync.Mutex
	enabled bool
	lines   []string
	sink    RequestLogSink
}{}

func ConfigureRequestDiagnostics(enabled bool) {
	cloudTrace.Lock()
	defer cloudTrace.Unlock()
	cloudTrace.enabled = enabled
	if !enabled {
		cloudTrace.lines = nil
	}
}
func RequestDiagnostics() string {
	cloudTrace.Lock()
	defer cloudTrace.Unlock()
	return strings.Join(cloudTrace.lines, "\n")
}
func driverLabel(s string) string {
	switch s {
	case "115 Open", "BaiduNetdisk", "AliyundriveOpen", "QuarkOpen", "123 Open", "Onedrive", "WebDav", "ThunderPlayer", "GuangyaPlayer":
		return strings.ReplaceAll(s, " ", "_")
	}
	return "other"
}
func operationLabel(route string) string {
	s, _, _ := strings.Cut(route, "?")
	switch s {
	case "/list", "/directory", "/list115", "/stat115", "/archive-stream", "/search", "/searchresolve", "/companions115", "/matches115", "/exists115", "/remove115", "/rename115", "/create", "/delete", "/update", "/account", "/accounts", "/comic":
		return s[1:]
	}
	return "other"
}
func (o *cloudOperation) record(stage string) {
	if o == nil {
		return
	}
	cloudTrace.Lock()
	if !cloudTrace.enabled {
		cloudTrace.Unlock()
		return
	}
	var mount uint64
	provider := "none"
	if o.mount != nil {
		mount = o.mount.number
		provider = o.mount.provider
	}
	line := fmt.Sprintf("%s pid=%d rid=%d %s=%d account=%d driver=%s op=%s stage=%s elapsed_ms=%d", time.Now().UTC().Format(time.RFC3339Nano), os.Getpid(), o.id, o.owner, o.caller, mount, provider, o.op, stage, time.Since(o.start).Milliseconds())
	if len(cloudTrace.lines) == 192 {
		copy(cloudTrace.lines, cloudTrace.lines[1:])
		cloudTrace.lines = cloudTrace.lines[:191]
	}
	cloudTrace.lines = append(cloudTrace.lines, line)
	sink := cloudTrace.sink
	cloudTrace.Unlock()
	if sink != nil {
		sink.Record(line)
	}
}

type traceKey struct{}

// RESTY's default retry logger includes the full request URL, which can contain
// credentials. Emit the operation and retry number through the sanitized trace.
type quietResty struct{}

func (quietResty) Errorf(string, ...interface{}) {}
func (quietResty) Warnf(string, ...interface{})  {}
func (quietResty) Debugf(string, ...interface{}) {}
func traceWire(ctx context.Context, tr *cloudOperation) context.Context {
	cloudTrace.Lock()
	enabled := cloudTrace.enabled
	cloudTrace.Unlock()
	if !enabled {
		return ctx
	}
	return httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GetConn: func(string) { tr.record("transport_start") },
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			if info.Err == nil {
				tr.record("wire_sent")
			}
		},
	})
}
func traceTransport() {
	for _, client := range []*resty.Client{base.RestyClient, base.NoRedirectClient} {
		client.SetLogger(quietResty{})
		client.OnBeforeRequest(func(_ *resty.Client, r *resty.Request) error {
			if tr, ok := r.Context().Value(traceKey{}).(*cloudOperation); ok {
				operation := "api"
				if r.QueryParam.Has("refresh_ui") || r.QueryParam.Get("grant_type") == "refresh_token" || r.FormData.Get("grant_type") == "refresh_token" || strings.HasSuffix(r.URL, "/oauth/access_token") {
					operation = "token_refresh"
				}
				tr.record("http_send attempt=" + strconv.Itoa(r.Attempt) + " operation=" + operation)
			}
			return nil
		})
		client.OnError(func(r *resty.Request, err error) {
			if tr, ok := r.Context().Value(traceKey{}).(*cloudOperation); ok {
				reason := "transport"
				var network net.Error
				if errors.Is(err, context.Canceled) {
					reason = "cancelled"
				} else if errors.As(err, &network) && network.Timeout() {
					reason = "timeout"
				}
				tr.record("http_error reason=" + reason)
			}
		})
	}
}

func traceRequest(ctx context.Context, route, body string) (string, *cloudOperation) {
	path, q := requestMount(route, body)
	owner, _ := ctx.Value(operationKey{}).(cloudCaller)
	if owner.kind == "" {
		owner.kind = "background"
	}
	return path, &cloudOperation{requestNumber.Add(1), owner.kind, owner.number, time.Now(), q, operationLabel(route)}
}
func dispatchRequest(ctx context.Context, method, route, body, path string, tr *cloudOperation) (string, error) {
	q := tr.mount
	ctx = traceWire(context.WithValue(ctx, traceKey{}, tr), tr)
	gate := requestMu
	if q != nil {
		gate = q.gate
	} else if tr.op == "comic" {
		gate = comicRequestMu
	}
	tr.record("queued")
	if q != nil {
		if holder := q.holder.Load(); holder != 0 {
			tr.record("waiting holder=" + strconv.FormatUint(holder, 10))
		}
	}
	select {
	case gate <- struct{}{}:
	case <-ctx.Done():
		tr.record("queue_cancelled")
		return "", ctx.Err()
	}
	if q != nil {
		q.holder.Store(tr.id)
	}
	tr.record("acquired")
	defer func() {
		if q != nil {
			q.holder.Store(0)
		}
		<-gate
		tr.record("released")
	}()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if q != nil && knownMount(path) != q {
		return "", errors.New("cloud account removed")
	}
	if api == nil || startErr != nil {
		return "", errors.New("cloud unavailable")
	}
	if q != nil && tr.op != "create" && tr.op != "account" && tr.op != "delete" {
		loadErr := q.load(ctx, tr)
		if err := ctx.Err(); err != nil {
			return "", err
		}
		// OpenList registers even a failed Init. Let a settings update repair it.
		if loadErr != nil && (tr.op != "update" || !op.HasStorage(path)) {
			return "", loadErr
		}
	}
	if q != nil && tr.op == "update" {
		var update struct {
			ID        uint
			MountPath string `json:"mount_path"`
		}
		if json.Unmarshal([]byte(body), &update) == nil && update.MountPath != "" && update.MountPath != path {
			mounts.Lock()
			if mounts.items[update.MountPath] != nil {
				mounts.Unlock()
				return "", errors.New("cloud mount already exists")
			}
			mounts.items[update.MountPath] = q
			mounts.Unlock()
			defer func() {
				if row, err := db.GetStorageById(update.ID); err == nil && row.MountPath == update.MountPath {
					q.forget(path)
				} else {
					q.forget(update.MountPath)
				}
			}()
		}
	}
	tr.record("dispatch")
	result, err := serveRequest(ctx, method, route, body)
	stage := "finished"
	if errors.Is(ctx.Err(), context.Canceled) {
		stage = "cancelled"
	} else if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		stage = "timeout"
	} else if err != nil {
		stage = "error"
	} else {
		var status struct{ Code int }
		if json.Unmarshal([]byte(result), &status) == nil {
			if status.Code >= 400 {
				stage = "error"
			} else if status.Code == http.StatusOK && tr.op == "update" && q != nil {
				q.pending.Store(0)
			}
		}
	}
	tr.record(stage)
	return result, err
}

type cloudCaller struct {
	kind   string
	number int64
}
