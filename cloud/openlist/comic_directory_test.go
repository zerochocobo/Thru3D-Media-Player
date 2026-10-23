package cloudcore

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestComicDirectoriesInSupportedAndEncryptedFormats(t *testing.T) {
	for _, name := range []string{"tree.zip", "tree-aes.zip", "tree.rar", "tree-encrypted.rar", "tree.7z", "tree-encrypted.7z"} {
		t.Run(name, func(t *testing.T) {
			source, _ := comicFixture(t, name)
			password := ""
			if strings.Contains(name, "encrypted") || strings.Contains(name, "aes") {
				password = "comic-test"
			}
			session, err := comicIndex(source, name, password)
			if err != nil {
				t.Fatal(err)
			}
			entries := session.listing("tree")
			found := map[string]string{}
			for _, item := range entries {
				found[item["path"].(string)] = item["kind"].(string)
			}
			for path, kind := range map[string]string{"empty": "folder", "chapter2": "folder", "chapter10": "folder", "chapter2/2.png": "image", "chapter10/10.png": "image", "cover.png": "image", "readme.txt": "file"} {
				if found[path] != kind {
					t.Fatalf("lost directory hierarchy: %s %s: %v", path, kind, found)
				}
			}
			session.dir = t.TempDir()
			for i := range session.pages {
				file, err := session.page(i)
				if err != nil {
					t.Fatal(err)
				}
				data, err := os.ReadFile(file)
				if err != nil || !bytes.HasPrefix(data, []byte("\x89PNG")) {
					t.Fatal("invalid selected nested image", err)
				}
			}
		})
	}
}

func TestComicEmptyAndDocumentOnlyArchivesAreBrowsable(t *testing.T) {
	for _, names := range [][]string{{}, {"empty/", "readme.txt"}} {
		var archive bytes.Buffer
		writer := zip.NewWriter(&archive)
		for _, name := range names {
			if _, err := writer.Create(name); err != nil {
				t.Fatal(err)
			}
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.ServeContent(w, r, "empty.zip", time.Unix(1, 0), bytes.NewReader(archive.Bytes()))
		}))
		source, err := newComicSource(t.Context(), server.URL)
		if err != nil {
			server.Close()
			t.Fatal(err)
		}
		session, err := comicIndex(source, "empty.zip", "")
		server.Close()
		if err != nil {
			t.Fatal("valid archive without images rejected", err)
		}
		if len(session.pages) != 0 || len(session.listing("empty")) != len(names) {
			t.Fatal("empty/document metadata lost")
		}
	}
}

func TestComicUnreadableVideoCodecDoesNotBlockPictureDirectory(t *testing.T) {
	var archive bytes.Buffer
	writer := zip.NewWriter(&archive)
	video, err := writer.CreateRaw(&zip.FileHeader{Name: "clip.mp4", Method: 93, CompressedSize64: 4, UncompressedSize64: 4})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = video.Write([]byte("data")); err != nil {
		t.Fatal(err)
	}
	image, err := writer.Create("page.png")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = image.Write([]byte("png")); err != nil {
		t.Fatal(err)
	}
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "mixed.zip", time.Unix(1, 0), bytes.NewReader(archive.Bytes()))
	}))
	defer server.Close()
	source, err := newComicSource(t.Context(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	session, err := comicIndex(source, "mixed.zip", "")
	if err != nil || len(session.pages) != 1 || len(session.listing("test")) != 2 {
		t.Fatal("unplayable video blocked picture browsing", err)
	}
	for _, entry := range session.listing("test") {
		if entry["path"] == "clip.mp4" && entry["uri"] != nil {
			t.Fatal("video received an extraction capability")
		}
	}
}

func TestComicDirectoryKeepsHierarchyWithoutOpeningFirstPage(t *testing.T) {
	var archive bytes.Buffer
	writer := zip.NewWriter(&archive)
	names := []string{"cover.png", "2章/2.png", "2章/10.png", "2章/附录/1.png", "10章/1.png", "empty/", "readme.txt"}
	for _, name := range names {
		file, err := writer.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if name == "empty/" {
			continue
		}
		data := []byte(name)
		if name == "cover.png" {
			data = bytes.Repeat([]byte("not eagerly read"), 1<<17)
		}
		if _, err = file.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	sent := 0
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sent++
		http.ServeContent(w, r, "tree.zip", time.Unix(1, 0), bytes.NewReader(archive.Bytes()))
	}))
	defer source.Close()
	api := gin.New()
	comicRoutes(api)
	call := func(body map[string]any) map[string]any {
		data, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		api.ServeHTTP(w, httptest.NewRequest("POST", "/comic", bytes.NewReader(data)))
		var response struct {
			Data map[string]any `json:"data"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.Data["error"] != nil {
			t.Fatal(response.Data)
		}
		return response.Data
	}
	opened := call(map[string]any{"op": "open", "url": source.URL, "name": "tree.zip", "cache": t.TempDir()})
	key := opened["session"].(string)
	defer call(map[string]any{"op": "close", "session": key})
	session := comicSessions[key]
	if len(session.cached) != 0 {
		t.Fatal("entering an unencrypted ZIP decoded a page")
	}
	if sent > 3 || session.source.bytes > 128<<10 {
		t.Fatal("listing fetched image bodies", sent, session.source.bytes)
	}
	entries := opened["entries"].([]any)
	if len(entries) != len(names) {
		t.Fatal("directory/file entries lost", entries)
	}
	var selected map[string]any
	for _, raw := range entries {
		entry := raw.(map[string]any)
		if entry["path"] == "2章/10.png" {
			selected = entry
		}
		if entry["path"] == "empty" && entry["kind"] != "folder" {
			t.Fatal("empty folder lost", entry)
		}
		if entry["path"] == "readme.txt" && (entry["kind"] != "file" || entry["uri"] != nil) {
			t.Fatal("unsupported entry got playable URI", entry)
		}
	}
	if selected == nil || selected["uri"] != "comic://"+key+"/1" {
		t.Fatal("selected nested page has wrong stable index", selected)
	}
	page := call(map[string]any{"op": "page", "session": key, "page": 1})
	data, err := os.ReadFile(page["path"].(string))
	if err != nil || string(data) != "2章/10.png" || len(session.cached) != 1 {
		t.Fatal("wrong page extracted", string(data), err)
	}
}
