package version

// Version is set at build time via -ldflags
var Version = "dev"

// CompareVersions returns -1 if a < b, 0 if a == b, +1 if a > b.
// Works with date-based version strings (e.g. "v2025.06.02-133859").
// "dev" is treated as always less than any real version.
func CompareVersions(a, b string) int {
	if a == b {
		return 0
	}
	if a == "dev" {
		return -1
	}
	if b == "dev" {
		return 1
	}
	if a < b {
		return -1
	}
	return 1
}
