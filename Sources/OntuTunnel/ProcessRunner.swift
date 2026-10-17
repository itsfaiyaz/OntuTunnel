import Foundation

/// Runs a service's start command (e.g. `bench start`) through a login
/// shell, so PATH and the user's profile are the same as in Terminal.
final class ProcessRunner {
    private(set) var process: Process?
    private var stopRequested = false
    let serviceName: String

    var onOutput: ((String, Bool) -> Void)?
    var onExit: ((Int32, Bool) -> Void)?   // exit code, was it requested

    init(serviceName: String) { self.serviceName = serviceName }

    var isRunning: Bool { process?.isRunning ?? false }

    func start(command: String, directory: String) throws {
        guard !isRunning else { return }
        stopRequested = false

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // exec: the command replaces the shell, so stopping it reaches the
        // real program (honcho/node) instead of an orphaned zsh
        task.arguments = ["-lc", "exec \(command)"]
        let dir = (directory as NSString).expandingTildeInPath
        if !dir.isEmpty { task.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["PYTHONUNBUFFERED"] = "1"
        task.environment = env

        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in self?.emit(h.availableData, isError: false) }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in self?.emit(h.availableData, isError: true) }

        task.terminationHandler = { [weak self] t in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.onExit?(t.terminationStatus, self.stopRequested)
        }
        try task.run()
        process = task
    }

    func stop() {
        guard let task = process, task.isRunning else { return }
        stopRequested = true
        task.interrupt()            // SIGINT — what Ctrl+C does in Terminal
        let pid = task.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if task.isRunning { kill(pid, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
            if task.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func emit(_ data: Data, isError: Bool) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        // strip ANSI colour codes
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        for line in clean.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            onOutput?(String(line), isError)
        }
    }
}
