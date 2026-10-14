package cloudcore

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"unicode"

	sdk "github.com/OpenListTeam/115-sdk-go"
	"github.com/gin-gonic/gin"
)

var diagnosticURL = regexp.MustCompile(`(?i)https?://[^\s<>"']+`)
var diagnosticHeader = regexp.MustCompile(`(?im)(cookie|set-cookie|authorization)\s*[:=][^\r\n]*`)
var diagnosticSecret = regexp.MustCompile(`(?i)("?(?:access_token|refresh_token|token|password|passwd|client_secret|secret|cookie|authorization|sign|signature|UID|CID|SEID|KID)"?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}&]+)`)

// Keep provider codes/messages, never request bodies, headers or signed links.
func cloudDiagnosticText(value string) string {
	value = diagnosticHeader.ReplaceAllString(value, "$1: [redacted]")
	value = diagnosticSecret.ReplaceAllString(value, "$1[redacted]")
	value = diagnosticURL.ReplaceAllStringFunc(value, func(raw string) string {
		if u, err := url.Parse(raw); err == nil && u.Hostname() != "" {
			return u.Scheme + "://" + u.Hostname() + "/[redacted]"
		}
		return "[URL redacted]"
	})
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return ' '
		}
		return r
	}, value)
	runes := []rune(strings.TrimSpace(value))
	if len(runes) > 2048 {
		return string(runes[:2048]) + "…"
	}
	return string(runes)
}

func cloudListError(c *gin.Context, stage string, err error) {
	detail := err.Error()
	var provider *sdk.Error
	if errors.As(err, &provider) {
		// OpenList wraps the error with directory paths. The typed SDK error
		// keeps the actual provider response without that private wrapper.
		detail = fmt.Sprintf("115 code: %d, message: %s", provider.Code, provider.Message)
	}
	c.JSON(200, gin.H{"code": 500, "message": "Cloud request failed", "error_detail": stage + "\n" + cloudDiagnosticText(detail)})
}
