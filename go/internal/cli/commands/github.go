package commands

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/wendylabsinc/wendy/go/internal/shared/version"
)

const githubAPIHost = "api.github.com"

func newGitHubAPIClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if req.URL == nil || req.URL.Scheme != "https" || !strings.EqualFold(req.URL.Host, githubAPIHost) {
				req.Header.Del("Authorization")
			}
			return nil
		},
	}
}

// newGitHubAPIGetRequest creates an authenticated GitHub API request when
// GITHUB_TOKEN is set. Callers should avoid logging the returned request because
// it may contain an Authorization header.
func newGitHubAPIGetRequest(rawURL string) (*http.Request, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "https" || !strings.EqualFold(parsed.Host, githubAPIHost) {
		return nil, fmt.Errorf("unsupported GitHub API URL: scheme=%q host=%q", parsed.Scheme, parsed.Host)
	}

	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", githubAPIUserAgent())
	// net/http header values are strings, so Go cannot zero this secret after use;
	// keep it scoped to this request and avoid logging the returned request.
	if token := strings.TrimSpace(os.Getenv("GITHUB_TOKEN")); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	return req, nil
}

func githubAPIUserAgent() string {
	v := strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r == '\x00' {
			return -1
		}
		return r
	}, version.Version)
	if v == "" {
		return "wendy"
	}
	return "wendy/" + v
}
