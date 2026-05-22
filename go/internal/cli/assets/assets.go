// Package assets embeds Wendy documentation and AI skill files for offline use.
package assets

import "embed"

// FS contains documentation and skill files embedded at compile time.
//
//go:embed docs skills
var FS embed.FS
