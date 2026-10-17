package main

import (
	"runtime"
	"syscall"
)

const (
	esContinuous     = 0x80000000
	esSystemRequired = 0x00000001
)

var (
	setThreadExecutionState = syscall.NewLazyDLL("kernel32.dll").NewProc("SetThreadExecutionState")
	awakeStop               chan struct{}
)

func keepAwakeOn() bool { return awakeStop != nil }

// The request belongs to the thread that made it, so one locked thread
// holds it until it's turned off.
func setKeepAwake(on bool) error {
	if !on {
		close(awakeStop)
		awakeStop = nil
		return nil
	}
	if err := setThreadExecutionState.Find(); err != nil {
		return err
	}
	stop := make(chan struct{})
	awakeStop = stop
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		setThreadExecutionState.Call(uintptr(esContinuous | esSystemRequired))
		<-stop
		setThreadExecutionState.Call(uintptr(esContinuous))
	}()
	return nil
}
