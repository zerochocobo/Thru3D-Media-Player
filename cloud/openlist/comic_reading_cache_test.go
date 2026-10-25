package cloudcore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestComicReadingFileOwnershipAndCancelledResponseCleanup(t *testing.T) {
	c := &comicSession{source: &comicSource{ctx: context.Background()}, dir: t.TempDir(), cached: map[int]string{}}
	for i := 0; i < 8; i++ {
		data := []byte(fmt.Sprintf("page %d verified bytes", i))
		c.pages = append(c.pages, comicPage{Name: fmt.Sprintf("%d.png", i), Size: int64(len(data)),
			open: func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(data)), nil }})
	}
	verified, err := c.page(7)
	if err != nil {
		t.Fatal(err)
	}
	files := []string{}
	for i := 0; i < 6; i++ {
		file, err := c.takePage(i, fmt.Sprintf("%032x", i))
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	if len(c.cached) != 0 || len(c.recent) != 0 {
		t.Fatal("hidden three-page LRU survived transfer")
	}
	if _, err := os.Stat(verified); !os.IsNotExist(err) {
		t.Fatal("password-check page leaked outside window")
	}
	newFile, err := c.takePage(0, strings.Repeat("a", 32))
	if err != nil || newFile == files[0] {
		t.Fatal("transfer identity reused", err)
	}
	for i, file := range files {
		data, err := os.ReadFile(file)
		if err != nil || string(data) != fmt.Sprintf("page %d verified bytes", i) {
			t.Fatal("leased page evicted or changed", i, err)
		}
	}
	for _, token := range []string{"", "../outside", strings.Repeat("z", 32)} {
		if _, err := c.takePage(0, token); err == nil {
			t.Fatal("unsafe transfer ticket accepted")
		}
	}
	api := gin.New()
	comicRoutes(api)
	comicSessions["reading-test"] = c
	t.Cleanup(func() { delete(comicSessions, "reading-test") })
	// A lost response is discarded using its known ticket. Repeated cleanup is safe.
	for i := 0; i < 2; i++ {
		body, _ := json.Marshal(map[string]any{"op": "discard-page", "session": "reading-test", "transfer": strings.Repeat("a", 32)})
		request := httptest.NewRequest(http.MethodPost, "/comic", bytes.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		api.ServeHTTP(response, request)
		if response.Code != 200 || strings.Contains(response.Body.String(), "error") {
			t.Fatal(response.Body.String())
		}
	}
	if _, err := os.Stat(newFile); !os.IsNotExist(err) {
		t.Fatal("orphan transfer survived cleanup")
	}
	if _, err := os.Stat(files[0]); err != nil {
		t.Fatal("cleanup deleted another transfer")
	}
}
