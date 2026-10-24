import Foundation
import Darwin

// Isolate each tool and its descendants in one process group, so cancelling a
// metadata request or stopping a recording never signals another application's
// FFmpeg, browser, or terminal process.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(64) }
let root = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().appendingPathComponent("LiveTools")
    .resolvingSymlinksInPath().standardizedFileURL
let executable = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().standardizedFileURL
guard executable.deletingLastPathComponent() == root,
      ["yt-dlp", "ffmpeg", "ffprobe", "deno"].contains(executable.lastPathComponent),
      FileManager.default.isExecutableFile(atPath: executable.path),
      setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(65) }
let strings = [executable.path] + Array(arguments.dropFirst(2))
var pointers = strings.map { strdup($0) }
pointers.append(nil)
executable.path.withCString { path in pointers.withUnsafeMutableBufferPointer { _ = execv(path, $0.baseAddress!) } }
for pointer in pointers { free(pointer) }
exit(127)
