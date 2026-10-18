//go:build !windows

package main

// Linux and macOS (the Go build): the dashboard opens in the browser.
const hasDesktop = false

func runDesktop(app *App, url string, openWindow bool) {}
