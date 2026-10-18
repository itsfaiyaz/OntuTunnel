//go:build windows

package main

import (
	_ "embed"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/getlantern/systray"
	webview2 "github.com/jchv/go-webview2"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// On Windows OntuTunnel is a desktop app: its own window (Microsoft Edge
// WebView2, built into Windows 10/11) and an icon next to the clock.
// Closing the window keeps it running there, like the Mac menu bar app.

//go:embed assets/ontutunnel.ico
var iconICO []byte

const hasDesktop = true

var (
	user32                = windows.NewLazySystemDLL("user32.dll")
	procShowWindow        = user32.NewProc("ShowWindow")
	procSetForeground     = user32.NewProc("SetForegroundWindow")
	procSendMessage       = user32.NewProc("SendMessageW")
	procLoadImage         = user32.NewProc("LoadImageW")
	procDpiContext        = user32.NewProc("SetProcessDpiAwarenessContext")
	procDPIAware          = user32.NewProc("SetProcessDPIAware")
	procGetDpiForSystem   = user32.NewProc("GetDpiForSystem")
	procSystemMetrics     = user32.NewProc("GetSystemMetrics")
	webView2DownloadPage  = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
	perMonitorAwareV2     = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4)
	swRestore             = uintptr(9)
	wmSetIcon             = uintptr(0x80)
	imageIcon             = uintptr(1)
	lrLoadFromFileDefault = uintptr(0x10 | 0x40)
)

type desktop struct {
	mu      sync.Mutex
	hwnd    uintptr
	opening bool
	url     string
	app     *App
}

// runDesktop shows the tray icon (and the window unless hidden) and blocks
// until Quit.
func runDesktop(app *App, url string, openWindow bool) {
	runtime.LockOSThread()
	if procDpiContext.Find() == nil {
		procDpiContext.Call(perMonitorAwareV2) // sharp text on scaled screens
	} else if procDPIAware.Find() == nil {
		procDPIAware.Call()
	}
	d := &desktop{url: url, app: app}
	app.ShowUI = d.show
	systray.Run(func() {
		systray.SetIcon(iconICO)
		systray.SetTitle("OntuTunnel")
		systray.SetTooltip("OntuTunnel")
		open := systray.AddMenuItem("Open OntuTunnel", "Show the OntuTunnel window")
		browser := systray.AddMenuItem("Open in browser", "Open the dashboard in your web browser")
		systray.AddSeparator()
		quit := systray.AddMenuItem("Quit OntuTunnel", "Stop OntuTunnel; your sites go offline")
		if openWindow {
			d.show()
		}
		go func() {
			for {
				select {
				case <-open.ClickedCh:
					d.show()
				case <-browser.ClickedCh:
					openBrowser(url)
				case <-quit.ClickedCh:
					systray.Quit()
					return
				}
			}
		}()
		go func() { // status in the tray tooltip
			for {
				systray.SetTooltip(app.TrayStatus())
				time.Sleep(5 * time.Second)
			}
		}()
	}, nil)
}

// show opens the window, or brings it to the front if it is already open.
func (d *desktop) show() {
	d.mu.Lock()
	if d.hwnd != 0 {
		h := d.hwnd
		d.mu.Unlock()
		procShowWindow.Call(h, swRestore)
		procSetForeground.Call(h)
		return
	}
	if d.opening {
		d.mu.Unlock()
		return
	}
	d.opening = true
	d.mu.Unlock()

	if !hasWebView2() {
		d.mu.Lock()
		d.opening = false
		d.mu.Unlock()
		d.app.Log("OntuTunnel", "Microsoft Edge WebView2 is missing, so the dashboard opens in your browser. Install WebView2 for the app window: "+webView2DownloadPage, true)
		openBrowser(d.url)
		return
	}
	ready := make(chan bool, 1)
	go func() {
		runtime.LockOSThread() // a window belongs to the thread that made it
		scale := uint(96)
		if procGetDpiForSystem.Find() == nil {
			if dpi, _, _ := procGetDpiForSystem.Call(); dpi > 0 {
				scale = uint(dpi)
			}
		}
		width, height := 1200*scale/96, 800*scale/96
		// never bigger than 90% of the screen (small laptops)
		if sw, _, _ := procSystemMetrics.Call(0); sw > 0 && width > uint(sw)*9/10 {
			width = uint(sw) * 9 / 10
		}
		if sh, _, _ := procSystemMetrics.Call(1); sh > 0 && height > uint(sh)*9/10 {
			height = uint(sh) * 9 / 10
		}
		w := webview2.NewWithOptions(webview2.WebViewOptions{
			DataPath:  filepath.Join(DataDir(), "webview"),
			AutoFocus: true,
			WindowOptions: webview2.WindowOptions{
				Title: "OntuTunnel", Width: width, Height: height, Center: true,
			},
		})
		if w == nil {
			ready <- false
			return
		}
		h := uintptr(w.Window())
		setWindowIcon(h)
		w.SetSize(int(720*scale/96), int(500*scale/96), webview2.HintMin)
		w.Navigate(d.url)
		d.mu.Lock()
		d.hwnd, d.opening = h, false
		d.mu.Unlock()
		ready <- true
		w.Run() // until the window is closed
		d.mu.Lock()
		d.hwnd = 0
		d.mu.Unlock()
	}()
	if !<-ready {
		d.mu.Lock()
		d.opening = false
		d.mu.Unlock()
		d.app.Log("OntuTunnel", "Microsoft Edge WebView2 is missing, so the dashboard opens in your browser. Install WebView2 for the app window: "+webView2DownloadPage, true)
		openBrowser(d.url)
	}
}

// hasWebView2: the Edge WebView2 runtime is installed (always on Windows 11,
// almost always on Windows 10).
func hasWebView2() bool {
	const id = `Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`
	for _, k := range []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\` + id},
		{registry.LOCAL_MACHINE, `SOFTWARE\` + id},
		{registry.CURRENT_USER, `SOFTWARE\` + id},
	} {
		key, err := registry.OpenKey(k.root, k.path, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		v, _, err := key.GetStringValue("pv")
		key.Close()
		if err == nil && v != "" && v != "0.0.0.0" {
			return true
		}
	}
	return false
}

func setWindowIcon(hwnd uintptr) {
	path := filepath.Join(DataDir(), "ontutunnel.ico")
	if err := os.WriteFile(path, iconICO, 0o644); err != nil {
		return
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	for _, size := range []uintptr{0, 1} { // ICON_SMALL, ICON_BIG
		if h, _, _ := procLoadImage.Call(0, uintptr(unsafe.Pointer(p)), imageIcon, 0, 0, lrLoadFromFileDefault); h != 0 {
			procSendMessage.Call(hwnd, wmSetIcon, size, h)
		}
	}
}
