import Foundation

/// Run an external tool with an explicit argv (no shell interpretation),
/// optionally feeding stdin. Returns exit status and combined output.
enum Subprocess {
    static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil
    ) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            let inputPipe = Pipe()
            process.standardInput = inputPipe

            try process.run()
            if let stdin {
                inputPipe.fileHandleForWriting.write(stdin)
            }
            try? inputPipe.fileHandleForWriting.close()
            // Drain while running so large output can't deadlock the pipe.
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}
