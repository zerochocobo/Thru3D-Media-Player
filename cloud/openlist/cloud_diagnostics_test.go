package cloudcore

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/gin-gonic/gin"
)

func TestCloudListFailureKeepsWrapped115ResponseWithoutPrivatePath(t *testing.T) {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	err := fmt.Errorf("failed list /private/account/云下载: %w", &sdk.Error{Code: 430004, Message: "文件夹不存在或无权限"})
	cloudListError(c, "list115.list", err)
	var result map[string]any
	if json.Unmarshal(w.Body.Bytes(), &result) != nil || result["code"] != float64(500) {
		t.Fatal(w.Body.String())
	}
	detail := result["error_detail"].(string)
	if !strings.Contains(detail, "115 code: 430004") || !strings.Contains(detail, "文件夹不存在或无权限") || !strings.Contains(detail, "list115.list") || strings.Contains(detail, "private/account") {
		t.Fatal("provider failure was lost or private wrapper leaked", detail)
	}
}

func TestCloudDiagnosticsRedactCredentialsAndSignedURLs(t *testing.T) {
	input := "code: 403, message: permission denied\nCookie: UID=cookie-secret; CID=cid-secret\nAuthorization: Bearer bearer-secret\n" +
		`{"access_token":"access-secret","refresh_token":"refresh-secret","password":"password-secret"} ` +
		"https://user:uri-secret@proapi.115.com/private?sign=signed-secret UID=uid-secret SEID=seid-secret"
	got := cloudDiagnosticText(input)
	for _, secret := range []string{"cookie-secret", "cid-secret", "bearer-secret", "access-secret", "refresh-secret", "password-secret", "uri-secret", "signed-secret", "uid-secret", "seid-secret"} {
		if strings.Contains(got, secret) {
			t.Fatal("secret leaked", secret, got)
		}
	}
	if !strings.Contains(got, "code: 403") || !strings.Contains(got, "permission denied") {
		t.Fatal("useful error lost", got)
	}
	quoted := cloudDiagnosticText(`{"cookie":"private-cookie","authorization":"private-auth"}`)
	if strings.Contains(quoted, "private-cookie") || strings.Contains(quoted, "private-auth") {
		t.Fatal("quoted credential leaked", quoted)
	}
	if len([]rune(cloudDiagnosticText(strings.Repeat("中", 9000)))) > 2049 {
		t.Fatal("unbounded diagnostic")
	}
}
