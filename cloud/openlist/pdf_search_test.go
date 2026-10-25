package cloudcore

import (
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"testing"
)

func TestPdfIsIncludedInAllCloudSearchWithoutPretendingItIsAPhoto(t *testing.T) {
	for _, name := range []string{"漫画.pdf", "漫画 #?%.PDF"} {
		file := &model.Object{Name: name}
		if !matchesSearch(file, "漫画", "all") {
			t.Fatal("PDF filtered out of cloud search", name)
		}
		for _, kind := range []string{"image", "video", "folder"} {
			if matchesSearch(file, "漫画", kind) {
				t.Fatal("PDF misclassified", kind)
			}
		}
	}
	if matchesSearch(&model.Object{Name: "漫画.pdf.exe"}, "漫画", "all") {
		t.Fatal("false extension accepted")
	}
}
