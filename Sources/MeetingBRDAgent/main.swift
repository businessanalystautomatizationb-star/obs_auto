import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer stdout so print() shows up promptly in the log file

// Headless escape hatch: `MeetingBRDAgent --process-file <path>` re-runs the pipeline
// on an already-recorded file (e.g. one OBS saved before a config/dependency issue
// was fixed) without going through OBS or the menu bar UI at all.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--process-file" {
    let path = CommandLine.arguments[2]
    let config = Config.loadOrCreateDefault()
    let pipeline = Pipeline(config: config)
    let semaphore = DispatchSemaphore(value: 0)
    pipeline.run(recordingPath: path) { message in
        print(message)
        if message.hasPrefix("Готово:") || message.hasPrefix("Ошибка") {
            semaphore.signal()
        }
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
