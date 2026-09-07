import AppKit

// Üst seviye kod nonisolated koşar; uygulama nesneleri ana aktöre aittir.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
