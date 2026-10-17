package main

import "sync"

var awakeMu sync.Mutex

// applyKeepAwake turns "Keep this computer awake" on or off to match the config.
func (a *App) applyKeepAwake() {
	on := a.store.Get().KeepAwake
	awakeMu.Lock()
	defer awakeMu.Unlock()
	if on == keepAwakeOn() {
		return
	}
	if err := setKeepAwake(on); err != nil {
		a.Log("Settings", "Couldn't keep the computer awake: "+err.Error(), true)
		return
	}
	if on {
		a.Log("Settings", "This computer will stay awake while OntuTunnel runs", false)
	}
}
