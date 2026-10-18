package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Update notice: asks GitHub for the latest release (at start, then twice a
// day) and shows "New version available" in the dashboard. Nothing is
// downloaded or installed by itself.

const releasesAPI = "https://api.github.com/repos/itsfaiyaz/OntuTunnel/releases/latest"

type UpdateInfo struct {
	Version string `json:"version"` // "1.1.3"
	URL     string `json:"url"`     // release page
}

func (a *App) watchUpdates() {
	for {
		if u, ok := latestRelease(); ok && newer(u.Version, Version) {
			a.mu.Lock()
			first := a.update.Version != u.Version
			a.update = u
			a.mu.Unlock()
			if first {
				a.Log("OntuTunnel", "New version "+u.Version+" is available: "+u.URL, false)
			}
		}
		time.Sleep(12 * time.Hour)
	}
}

func latestRelease() (UpdateInfo, bool) {
	req, _ := http.NewRequest(http.MethodGet, releasesAPI, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "OntuTunnel/"+Version)
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return UpdateInfo{}, false
	}
	defer resp.Body.Close()
	var r struct {
		Tag  string `json:"tag_name"`
		URL  string `json:"html_url"`
		Pre  bool   `json:"prerelease"`
		Drft bool   `json:"draft"`
	}
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&r) != nil || r.Pre || r.Drft ||
		!strings.HasPrefix(r.URL, "https://github.com/itsfaiyaz/OntuTunnel/") {
		return UpdateInfo{}, false
	}
	return UpdateInfo{Version: strings.TrimPrefix(r.Tag, "v"), URL: r.URL}, true
}

// newer: is version a (e.g. "1.1.10") newer than b ("1.1.9")? A "dev" build
// never asks.
func newer(a, b string) bool {
	if b == "dev" || a == "" {
		return false
	}
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}
