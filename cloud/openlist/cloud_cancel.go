package cloudcore

import (
	"context"
	"errors"
	"sync"
	"time"
)

type pendingCloudRequest struct {
	context context.Context
	cancel  context.CancelFunc
	expires time.Time
}

var cloudRequestContexts = struct {
	sync.Mutex
	items map[string]pendingCloudRequest
}{items: map[string]pendingCloudRequest{}}

// Allocate before Kotlin installs its cancellation callback, so cancellation
// cannot race the registration of a JNI call waiting for requestMu.
func NewRequest() (string, error) {
	return NewTrackedRequest("background", 0)
}

// NewTrackedRequest links the Kotlin browse or playback generation to its Go stages.
func NewTrackedRequest(kind string, number int64) (string, error) {
	switch kind {
	case "browse", "playback", "background":
	default:
		kind = "background"
	}
	budget := 25 * time.Second
	if kind == "playback" {
		budget = 90 * time.Second
	}
	key := searchKey()
	if key == "" {
		return "", errors.New("cloud request unavailable")
	}
	ctx, cancel := context.WithTimeout(context.WithValue(context.Background(), operationKey{}, cloudCaller{kind, number}), budget)
	cloudRequestContexts.Lock()
	defer cloudRequestContexts.Unlock()
	for id, item := range cloudRequestContexts.items {
		if time.Now().After(item.expires) {
			item.cancel()
			delete(cloudRequestContexts.items, id)
		}
	}
	if len(cloudRequestContexts.items) >= 64 {
		cancel()
		return "", errors.New("too many cloud requests")
	}
	cloudRequestContexts.items[key] = pendingCloudRequest{ctx, cancel, time.Now().Add(budget)}
	return key, nil
}
func CancelRequest(key string) {
	cloudRequestContexts.Lock()
	item, ok := cloudRequestContexts.items[key]
	delete(cloudRequestContexts.items, key)
	cloudRequestContexts.Unlock()
	if ok {
		item.cancel()
	}
}
func RequestCancelable(method, route, body, key string) (string, error) {
	cloudRequestContexts.Lock()
	item, ok := cloudRequestContexts.items[key]
	// A remote RAR may have many separated headers. Keep its user-cancellable
	// index operation alive without changing the ordinary 25-second API budget.
	if ok && route == "/comic" && item.context.Err() == nil {
		item.cancel()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		item = pendingCloudRequest{ctx, cancel, time.Now().Add(10 * time.Minute)}
		cloudRequestContexts.items[key] = item
	}
	cloudRequestContexts.Unlock()
	if !ok {
		return "", errors.New("cloud request expired")
	}
	defer func() {
		item.cancel()
		cloudRequestContexts.Lock()
		delete(cloudRequestContexts.items, key)
		cloudRequestContexts.Unlock()
	}()
	switch route {
	case "/directory", "/list", "/list115", "/stat115", "/archive-stream", "/search", "/searchresolve", "/matches115", "/companions115", "/exists115":
	default:
		return requestContext(item.context, method, route, body)
	}
	path, tr := traceRequest(item.context, route, body)
	// Some upstream drivers can still be unwinding a transport after cancellation.
	// Keep their account gate until they exit, but release the calling Android worker now.
	type result struct {
		value string
		err   error
	}
	done := make(chan result, 1)
	go func() { v, e := dispatchRequest(item.context, method, route, body, path, tr); done <- result{v, e} }()
	select {
	case r := <-done:
		if item.context.Err() == nil {
			return r.value, r.err
		}
	case <-item.context.Done():
	}
	if errors.Is(item.context.Err(), context.DeadlineExceeded) {
		tr.record("caller_timeout")
	} else {
		tr.record("caller_cancelled")
	}
	return "", item.context.Err()
}
