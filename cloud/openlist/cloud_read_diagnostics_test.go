package cloudcore

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestCloudReadDiagnosticsKeepOnlyBoundedNonAddressMessages(t *testing.T) {
	ConfigureReadDiagnostics(true)
	t.Cleanup(func() { ConfigureReadDiagnostics(false) })
	for _, tc := range []struct{ body, reason, message string }{
		{`{"message":"no cookie value"}`, "cdn_cookie_missing", "no cookie value"},
		{`{"message":"no user-agent"}`, "cdn_ua_missing", "no user-agent"},
		{`{"message":"expired url"}`, "cdn_expired", "expired url"},
		{`{"message":"115 pmt 3-2"}`, "cdn_connections_limited", "115 pmt 3-2"},
		{`{"message":"115 pmt 4-2"}`, "cdn_connections_limited", "115 pmt 4-2"},
		{`{"message":"https://private.invalid/movie?token=secret"}`, "upstream_error", ""},
		{`{"message":"/private/film.mp4"}`, "upstream_error", ""},
		{`{"message":"Cookie:secret"}`, "upstream_error", ""},
		{`<html>private body</html>`, "upstream_error", ""},
	} {
		reason, message := readDenial(errors.New("http request [https://private.invalid/?secret] failure,status:403 response:" + tc.body))
		if reason != tc.reason || message != tc.message {
			t.Fatal(reason, message)
		}
		recordReadDiagnostic(403, reason, message, true)
	}
	for i := 0; i < 10; i++ {
		recordReadDiagnostic(403, "cdn_cookie_missing", "no cookie value", true)
	}
	items := readDiagnosticSnapshot()
	if len(items) != 8 {
		t.Fatal("unbounded read diagnostic", len(items))
	}
	raw, _ := json.Marshal(items)
	for _, private := range []string{"private", "secret", "http://", "https://", ".mp4"} {
		if strings.Contains(string(raw), private) {
			t.Fatal("private read material escaped")
		}
	}
	ConfigureReadDiagnostics(false)
	recordReadDiagnostic(403, "cdn_cookie_missing", "no cookie value", true)
	if len(readDiagnosticSnapshot()) != 0 {
		t.Fatal("disabled diagnostics retained a message")
	}
}
