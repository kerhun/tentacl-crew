import Foundation
import Darwin

// tentacld: the PTY daemon. One JSON object per line over a unix socket (see Server.swift for the verbs).
//   tentacld [--socket PATH]      default ~/Library/Application Support/Tentacl/term.sock

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
_ = setsid()   // no-op when already a group leader; otherwise the daemon outlives the app that started it

var socketPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tentacl/term.sock").path
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    if a == "--socket", let p = args.popFirst() { socketPath = p }
}

let server = Server(path: socketPath)
switch server.start() {
case .listening:
    server.run()
case .alreadyRunning:
    exit(0)
case .failed(let why):
    FileHandle.standardError.write(Data("tentacld: \(why)\n".utf8))
    exit(1)
}
