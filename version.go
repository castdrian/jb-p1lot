package jbp1lot

import (
	_ "embed"
	"strings"
)

//go:embed VERSION
var rawVersion string

var Version = strings.TrimSpace(rawVersion)
