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
	key := searchKey()
	if key == "" {
		return "", errors.New("cloud request unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
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
	cloudRequestContexts.items[key] = pendingCloudRequest{ctx, cancel, time.Now().Add(25 * time.Second)}
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
	return requestContext(item.context, method, route, body)
}
