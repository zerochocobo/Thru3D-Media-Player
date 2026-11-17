package thunder

// Domestic Thunder login reuses the pinned upstream protocol. Usernames and
// passwords are only used by this exchange, never added to a persisted mount.
import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/go-resty/resty/v2"
)

var playerEnabled atomic.Bool
var playerClientFactory = base.NewRestyClient

func EnablePlayer(enabled bool) { playerEnabled.Store(enabled) }

type PlayerCredential struct {
	driver.RootID
	RefreshToken string `json:"refresh_token"`
	DeviceID     string `json:"device_id"`
	CaptchaToken string `json:"captcha_token"`
}
type PlayerLoginRequest struct {
	Username     string `json:"username"`
	Password     string `json:"password"`
	DeviceID     string `json:"device_id"`
	CreditKey    string `json:"credit_key"`
	CaptchaToken string `json:"captcha_token"`
}
type PlayerChallenge struct {
	Kind   string      `json:"kind"`
	URL    string      `json:"url"`
	Review *ReviewData `json:"review,omitempty"`
}
type PlayerLoginResult struct {
	DeviceID   string            `json:"device_id"`
	Credential *PlayerCredential `json:"credential,omitempty"`
	Challenge  *PlayerChallenge  `json:"challenge,omitempty"`
}

func playerCommon(ctx context.Context, device, captcha string) *XunLeiCommon {
	// Reuse defaults from pinned upstream metadata, including its client identity.
	defaults := map[string]string{}
	fields := reflect.TypeOf(ExpertAddition{})
	for i := 0; i < fields.NumField(); i++ {
		f := fields.Field(i)
		if value := f.Tag.Get("default"); value != "" {
			defaults[f.Name] = value
		}
	}
	client := playerClientFactory().SetTimeout(25 * time.Second).SetRetryCount(0)
	if ctx != nil {
		client.OnBeforeRequest(func(_ *resty.Client, r *resty.Request) error { r.SetContext(ctx); return ctx.Err() })
	}
	return &XunLeiCommon{Common: &Common{
		client: client, DeviceID: device, ClientID: defaults["ClientID"], ClientSecret: defaults["ClientSecret"],
		ClientVersion: defaults["ClientVersion"], PackageName: defaults["PackageName"],
		UserAgent: defaults["UserAgent"], DownloadUserAgent: defaults["DownloadUserAgent"],
		Algorithms: strings.Split(defaults["Algorithms"], ","), captchaToken: captcha,
	}}
}

func playerSafeError(err error) error {
	if err == nil {
		return nil
	}
	var response *ErrResp
	if errors.As(err, &response) {
		return fmt.Errorf("thunder login/API declined (%d)", response.ErrorCode)
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	return errors.New("thunder request failed; sign in again if the session expired")
}

func PlayerVerificationURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return host == "xunlei.com" || strings.HasSuffix(host, ".xunlei.com") || host == "xl.com" || strings.HasSuffix(host, ".xl.com")
}

func playerChallenge(err error) *PlayerChallenge {
	if err == nil {
		return nil
	}
	message := err.Error()
	if len(message) > 32768 {
		return nil
	}
	if begin := strings.Index(message, "<code>"); begin >= 0 {
		rest := message[begin+6:]
		if end := strings.Index(rest, "</code>"); end >= 0 {
			var review ReviewData
			if json.Unmarshal([]byte(html.UnescapeString(rest[:end])), &review) == nil &&
				review.Creditkey != "" && review.Deviceid != "" && PlayerVerificationURL(review.Reviewurl) {
				return &PlayerChallenge{Kind: "review", URL: "https://i.xunlei.com/xlcaptcha/android.html", Review: &review}
			}
		}
	}
	const prefix = `need verify: <a target="_blank" href="`
	if strings.HasPrefix(message, prefix) {
		if raw, _, ok := strings.Cut(strings.TrimPrefix(message, prefix), `">`); ok && PlayerVerificationURL(raw) {
			return &PlayerChallenge{Kind: "captcha", URL: raw}
		}
	}
	return nil
}

func PlayerLogin(ctx context.Context, request PlayerLoginRequest) (*PlayerLoginResult, error) {
	if !playerEnabled.Load() {
		return nil, errors.New("thunder login unavailable")
	}
	request.Username = strings.TrimSpace(request.Username)
	if request.Username == "" || len(request.Username) > 256 || request.Password == "" || len(request.Password) > 1024 ||
		len(request.CreditKey) > 8192 || len(request.CaptchaToken) > 8192 {
		return nil, errors.New("invalid thunder login fields")
	}
	if request.DeviceID == "" {
		random := make([]byte, 16)
		if _, err := rand.Read(random); err != nil {
			return nil, errors.New("device identity unavailable")
		}
		request.DeviceID = hex.EncodeToString(random)
	}
	decoded, err := hex.DecodeString(request.DeviceID)
	if err != nil || len(decoded) != 16 {
		return nil, errors.New("invalid thunder device identity")
	}
	common := playerCommon(ctx, request.DeviceID, request.CaptchaToken)
	common.SetCreditKey(request.CreditKey)
	token, err := common.Login(request.Username, request.Password)
	result := &PlayerLoginResult{DeviceID: request.DeviceID}
	if err != nil {
		if result.Challenge = playerChallenge(err); result.Challenge != nil {
			return result, nil
		}
		return nil, playerSafeError(err)
	}
	if token == nil || token.AccessToken == "" || token.RefreshToken == "" {
		return nil, errors.New("thunder returned an empty login token")
	}
	result.Credential = &PlayerCredential{RefreshToken: token.RefreshToken, DeviceID: request.DeviceID, CaptchaToken: common.GetCaptchaToken()}
	return result, ctx.Err()
}
