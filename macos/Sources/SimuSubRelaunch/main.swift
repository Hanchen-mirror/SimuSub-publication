import Darwin
import Foundation

// This child stays alive after the old app exits. Launch Services only starts
// the replacement after the old process is completely gone.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let parentPID = Int32(arguments[0]), parentPID > 1 else { exit(2) }
let appURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
guard appURL.pathExtension == "app",
      let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
      ["com.mirror.simusub", "com.mirror.simusub.v2preview"].contains(info["CFBundleIdentifier"] as? String ?? "") else { exit(2) }
let deadline = Date().addingTimeInterval(30)
while kill(parentPID, 0) == 0 || errno == EPERM {
    guard Date() < deadline else { exit(3) }
    usleep(100_000)
}
let opener = Process()
opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
opener.arguments = ["-n", appURL.path] + (arguments.count > 2 ? ["--args"] + Array(arguments.dropFirst(2)) : [])
do {
    try opener.run()
    opener.waitUntilExit()
    exit(opener.terminationStatus)
} catch {
    fputs("simuSub relaunch failed: \(error.localizedDescription)\n", stderr)
    exit(4)
}
