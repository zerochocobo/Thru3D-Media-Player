package cloudcore

import (
	"encoding/json"
	"regexp"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
)

type cloudReadDiagnostic struct {
	Status           int    `json:"status"`
	Reason           string `json:"reason"`
	Message          string `json:"message,omitempty"`
	UserAgentMatches bool   `json:"user_agent_matches"`
}

var cloudReads = struct {
	sync.Mutex
	enabled bool
	items   []cloudReadDiagnostic
}{}

// ConfigureReadDiagnostics is called only with the Android build/privacy gate.
// The bounded in-memory messages are readable through JNI management only.
func ConfigureReadDiagnostics(enabled bool) {
	cloudReads.Lock()
	defer cloudReads.Unlock()
	cloudReads.enabled = enabled
	if !enabled {
		cloudReads.items = nil
	}
}

var cloudReadMessage = regexp.MustCompile(`^[A-Za-z][A-Za-z _-]{0,95}$`)
var cloudReadPmt = regexp.MustCompile(`^115 pmt ([0-9]{1,3})-([0-9]{1,3})$`)

func readDenial(err error) (string, string) {
	_, body, ok := strings.Cut(err.Error(), " response:")
	if !ok {
		return "upstream_error", ""
	}
	var reply struct {
		Message string `json:"message"`
	}
	if json.Unmarshal([]byte(body), &reply) != nil {
		return "upstream_error", ""
	}
	message := strings.TrimSpace(reply.Message)
	if cloudReadPmt.MatchString(message) {
		return "cdn_connections_limited", message
	}
	if !cloudReadMessage.MatchString(message) {
		return "upstream_error", ""
	}
	reason := map[string]string{
		"no cookie value":      "cdn_cookie_missing",
		"invalid cookie value": "cdn_cookie_invalid",
		"no user-agent":        "cdn_ua_missing",
		"no user agent":        "cdn_ua_missing",
		"expired url":          "cdn_expired",
		"invalid expired":      "cdn_expired",
		"invalid verify":       "cdn_signature_invalid",
		"no verify":            "cdn_signature_missing",
		"ip not match":         "cdn_ip_mismatch",
		"too many requests":    "cdn_rate_limited",
	}[strings.ToLower(message)]
	if reason == "" {
		reason = "upstream_error"
	}
	return reason, message
}

func recordReadDiagnostic(status int, reason, message string, matches bool) {
	cloudReads.Lock()
	defer cloudReads.Unlock()
	if !cloudReads.enabled {
		return
	}
	cloudReads.items = append(cloudReads.items, cloudReadDiagnostic{status, reason, message, matches})
	if len(cloudReads.items) > 8 {
		cloudReads.items = append([]cloudReadDiagnostic(nil), cloudReads.items[len(cloudReads.items)-8:]...)
	}
}

func readDiagnosticSnapshot() []cloudReadDiagnostic {
	cloudReads.Lock()
	defer cloudReads.Unlock()
	if !cloudReads.enabled {
		return []cloudReadDiagnostic{}
	}
	return append([]cloudReadDiagnostic(nil), cloudReads.items...)
}

func readDiagnosticRoutes(api *gin.Engine) {
	api.GET("/read_diagnostics", func(c *gin.Context) { c.JSON(200, gin.H{"code": 200, "data": readDiagnosticSnapshot()}) })
}
