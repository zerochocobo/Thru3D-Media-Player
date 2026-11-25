package cloudcore

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"regexp"
	"strings"
	"sync"

	"github.com/OpenListTeam/OpenList/v4/internal/errs"
	cloudnet "github.com/OpenListTeam/OpenList/v4/internal/net"
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

// markReadFailure names where a loopback read failed and the kind of error, for the
// client's failure report in every build. Only fixed labels: never the error text,
// which can carry provider URLs or paths.
func markReadFailure(c *gin.Context, step string, err error) {
	c.Header("X-Thru3D-Read-Step", step)
	if class := readErrorClass(err); class != "" {
		c.Header("X-Thru3D-Read-Error", class)
	}
}

// A recovered panic still answers 500, now labelled for the client's report.
func recoverStream(c *gin.Context, _ any) {
	markReadFailure(c, "panic", nil)
	c.AbortWithStatus(500)
}

// OpenList's own proxy writes its errors without our labels; this marks which path served the read.
func markLegacyStream(c *gin.Context) {
	c.Header("X-Thru3D-Read-Step", "legacy")
	c.Next()
}

func readErrorClass(err error) string {
	var dns *net.DNSError
	var status cloudnet.HttpStatusCodeError
	var timeout net.Error
	var op *net.OpError
	var record tls.RecordHeaderError
	var verify *tls.CertificateVerificationError
	var authority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	switch {
	case err == nil:
		return ""
	case errors.As(err, &dns):
		return "dns"
	case errors.Is(err, context.DeadlineExceeded) || errors.As(err, &timeout) && timeout.Timeout():
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.As(err, &status):
		return "http"
	case errors.As(err, &record) || errors.As(err, &verify) || errors.As(err, &authority) ||
		errors.As(err, &hostname) || errors.As(err, &invalid) || strings.Contains(err.Error(), "tls: "):
		return "tls"
	case errors.As(err, &op) && op.Op == "dial":
		return "connect"
	case errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF):
		return "eof"
	case errors.As(err, &op):
		return "network"
	case errors.Is(err, errs.ObjectNotFound):
		return "not_found"
	case errors.Is(err, errs.StorageNotFound):
		return "storage"
	}
	return "other"
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
