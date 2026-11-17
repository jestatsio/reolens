import Foundation
import ReolensCLIKit
import ReolensClient
import ReolensCore
import ReolensMCP

/// `reolens-cli` — thin executable shell. All parsing/dispatch lives in
/// ReolensCLIKit; this file only moves bytes (argv in, stdout/stderr
/// out, stdio for the MCP server) and sets the exit code.
///
/// A client of Reolens for Mac's Local API: set REOLENS_API_TOKEN (copy
/// it in Settings → Local API) and, if the Mac is remote on your LAN,
/// REOLENS_API_URL. Camera passwords never enter this process.
@main
struct ReolensCLIMain {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        switch CLIParse.parse(argv: argv) {
        case .help:
            write(stdout: CLIHelp.usage + "\n")
            exit(CLIExit.ok)
        case .failure(let message):
            write(stderr: "reolens-cli: \(message)\nRun 'reolens-cli --help' for usage.\n")
            exit(CLIExit.usage)
        case .mcpServer(let config):
            await runMCPServer(config: config)
            exit(CLIExit.ok)
        case .run(let config, let command):
            let api = RemoteCameraAPI(baseURL: config.baseURL, token: config.token)
            let outcome = await CLIRunner().run(command, config: config, api: api, eventSink: { line in
                FileHandle.standardOutput.write(Data(line.utf8))
            })
            if !outcome.stdout.isEmpty { write(stdout: outcome.stdout) }
            if !outcome.stderr.isEmpty { write(stderr: outcome.stderr) }
            exit(outcome.exitCode)
        }
    }

    /// MCP over stdio: one JSON-RPC message per line, handled in order.
    /// Diagnostics must never go to stdout (it is the protocol channel);
    /// this loop writes nothing else there.
    private static func runMCPServer(config: CLIConfig) async {
        let api = RemoteCameraAPI(baseURL: config.baseURL, token: config.token)
        let server = MCPServer(api: api, serverVersion: reolensCLIVersion)
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                if let response = await server.handle(line: line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
        } catch {
            // stdin closed or unreadable: the host ended the session.
        }
    }

    private static func write(stdout text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func write(stderr text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
