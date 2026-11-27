package _115_open

import (
	"context"
	"net/http"

	sdk "github.com/OpenListTeam/115-sdk-go"
	"resty.dev/v3"
)

// A cancelled browse or playback must not abandon a refresh the server may
// already have accepted: 115 rotates the refresh token, so losing the answer
// signs the account out. Only the token exchange outlives its caller.
type detachedRefresh struct{ base http.RoundTripper }

func (t detachedRefresh) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL != nil && r.URL.Scheme+"://"+r.URL.Host+r.URL.Path == sdk.ApiRefreshToken {
		r = r.WithContext(context.WithoutCancel(r.Context()))
	}
	return t.base.RoundTrip(r)
}

// Keep Resty's default transport and cookie jar; nil selects that transport.
func playerClientOption(base http.RoundTripper) sdk.Option {
	client := resty.New()
	if base == nil {
		base = client.Transport()
	}
	return sdk.WithRestyClient(client.SetTransport(detachedRefresh{base}))
}
