package guangya_open

// GuangYaPan open platform Web OAuth with PKCE. The player's own login page
// intercepts the registered redirect; no server holds a secret for this flow.
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/go-resty/resty/v2"
)

const RedirectURI = "thru3d://oauth/guangyapan"

// Variables only so tests can point them at a local server.
var (
	apiBase     = "https://openapi.guangyapan.com"
	accountBase = "https://openapi-account.guangyapan.com"
)

// One client per store package; neither is a secret.
var clientIDs = map[string]bool{"av7rsoJS2g0dIaXH": true, "av7r1lQqdEuV1Er3": true}
var verifierPattern = regexp.MustCompile(`^[A-Za-z0-9._~-]{43,128}$`)
var errorPattern = regexp.MustCompile(`^[a-z_]{1,64}$`)
var playerClientFactory = func() *resty.Client { return resty.New().SetTimeout(15 * time.Second) }

type PlayerAuthRequest struct {
	ClientID     string `json:"client_id"`
	Code         string `json:"code"`
	CodeVerifier string `json:"code_verifier"`
}
type PlayerAuthResult struct {
	Credential *PlayerCredential `json:"credential"`
}
type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	Code         *int   `json:"code"`
}

func PlayerAuth(ctx context.Context, request PlayerAuthRequest) (*PlayerAuthResult, error) {
	if !clientIDs[request.ClientID] || request.Code == "" || len(request.Code) > 2048 || !verifierPattern.MatchString(request.CodeVerifier) {
		return nil, errors.New("invalid guangya sign-in fields")
	}
	response, err := playerClientFactory().R().SetContext(ctx).SetHeader("x-client-id", request.ClientID).
		SetBody(map[string]string{"client_id": request.ClientID, "grant_type": "authorization_code", "code": request.Code,
			"code_verifier": request.CodeVerifier, "redirect_uri": RedirectURI}).
		Post(accountBase + "/v1/auth/token")
	if err != nil {
		return nil, safeNetworkError(err)
	}
	token, err := parseToken(response)
	if err != nil {
		return nil, err
	}
	return &PlayerAuthResult{Credential: &PlayerCredential{ClientID: request.ClientID, RefreshToken: token.RefreshToken}}, nil
}

func parseToken(response *resty.Response) (*tokenResponse, error) {
	var token tokenResponse
	if json.Unmarshal(response.Body(), &token) != nil {
		if text := strings.TrimSpace(string(response.Body())); errorPattern.MatchString(text) {
			return nil, fmt.Errorf("guangya sign-in declined (%s)", text)
		}
		return nil, fmt.Errorf("guangya sign-in unavailable (HTTP %d)", response.StatusCode())
	}
	if token.AccessToken == "" || token.RefreshToken == "" || len(token.AccessToken) > 16384 || len(token.RefreshToken) > 16384 {
		if token.Code != nil {
			return nil, fmt.Errorf("guangya sign-in declined (%d)", *token.Code)
		}
		return nil, errors.New("guangya sign in required")
	}
	return &token, nil
}

func safeNetworkError(err error) error {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	return errors.New("guangya request failed; check the network")
}
