package commands

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/wendylabsinc/wendy/go/internal/shared/version"
)

func TestNewGitHubAPIGetRequestWithoutToken(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "")

	req, err := newGitHubAPIGetRequest(githubReleasesURL)
	if err != nil {
		t.Fatalf("newGitHubAPIGetRequest: %v", err)
	}

	if req.Method != http.MethodGet {
		t.Fatalf("method = %q; want %q", req.Method, http.MethodGet)
	}
	if got := req.Header.Get("Authorization"); got != "" {
		t.Fatalf("Authorization = %q; want empty", got)
	}
	if got := req.Header.Get("User-Agent"); got == "" {
		t.Fatal("User-Agent should be set")
	}
}

func TestNewGitHubAPIGetRequestWithToken(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "secret-token")

	req, err := newGitHubAPIGetRequest(githubReleasesURL)
	if err != nil {
		t.Fatalf("newGitHubAPIGetRequest: %v", err)
	}

	if got, want := req.Header.Get("Authorization"), "Bearer secret-token"; got != want {
		t.Fatalf("Authorization = %q; want %q", got, want)
	}
}

func TestNewGitHubAPIGetRequestRejectsNonGitHubAPIURL(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "secret-token")

	if _, err := newGitHubAPIGetRequest("https://example.com/releases"); err == nil {
		t.Fatal("expected error for non-GitHub API URL")
	}
	if _, err := newGitHubAPIGetRequest("http://api.github.com/releases"); err == nil {
		t.Fatal("expected error for non-HTTPS GitHub API URL")
	}
}

func TestGitHubAPIClientStripsAuthorizationOnExternalRedirect(t *testing.T) {
	client := newGitHubAPIClient(0)
	redirectURL, err := url.Parse("https://example.com/redirect")
	if err != nil {
		t.Fatalf("url.Parse: %v", err)
	}
	req := &http.Request{URL: redirectURL, Header: make(http.Header)}
	req.Header.Set("Authorization", "Bearer secret-token")

	if err := client.CheckRedirect(req, nil); err != nil {
		t.Fatalf("CheckRedirect: %v", err)
	}
	if got := req.Header.Get("Authorization"); got != "" {
		t.Fatalf("Authorization after redirect = %q; want empty", got)
	}
}

func TestGitHubAPIUserAgentSanitizesVersion(t *testing.T) {
	oldVersion := version.Version
	version.Version = "1.2.3\r\nInjected: true\x00"
	t.Cleanup(func() { version.Version = oldVersion })

	if got, want := githubAPIUserAgent(), "wendy/1.2.3Injected: true"; got != want {
		t.Fatalf("githubAPIUserAgent = %q; want %q", got, want)
	}
}
