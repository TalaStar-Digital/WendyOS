import Foundation
import Subprocess
import Testing

@testable import WendyE2ETesting

@Suite
struct `machine` {
    @Test
    func `creates SSH machine`() {
        let machine = Machine(
            name: "SSH",
            ssh: "ai@example.local",
            workingDirectory: "~/wendy-agent"
        )

        #expect(machine.name == "SSH")
        #expect(machine.ssh == "ai@example.local")
        #expect(machine.workingDirectory == "~/wendy-agent")
        #expect(machine.verbose == false)
        #expect(machine.id == "ai@example.local:~/wendy-agent")
        #expect(machine.description == "ai@example.local:~/wendy-agent")
    }

    @Test
    func `creates verbose machine`() {
        let machine = Machine(name: "Local", verbose: true)

        #expect(machine.verbose)
    }

    @Test
    func `defaults to SSH user home directory`() {
        let machine = Machine(name: "SSH", ssh: "ai@example.local")

        #expect(machine.ssh == "ai@example.local")
        #expect(machine.workingDirectory == nil)
        #expect(machine.id == "ai@example.local:~")
        #expect(machine.description == "ai@example.local:~")
    }

    @Test
    func `defaults local machine to current directory`() {
        let machine = Machine(name: "Local")

        #expect(machine.ssh == nil)
        #expect(machine.workingDirectory == FileManager.default.currentDirectoryPath)
        #expect(machine.id == "local:\(FileManager.default.currentDirectoryPath)")
        #expect(machine.description == "local:\(FileManager.default.currentDirectoryPath)")
    }

    @Test
    func `runs a simple command`() async throws {
        let machine = Machine(name: "Local")
        let record = try await machine.run(
            "printf 'wendy-machine-smoke'",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput == "wendy-machine-smoke")
        #expect(record.standardError == "")
    }

    @Test
    func `runs local commands in working directory`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-local-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let machine = Machine(name: "Local", workingDirectory: directory.path)
        try await machine.run("touch local.txt")

        #expect(machine.ssh == nil)
        #expect(machine.workingDirectory == directory.path)
        #expect(machine.description == "local:\(directory.path)")
        #expect(FileManager.default.fileExists(atPath: directory.path + "/local.txt"))
    }

    @Test
    func `runs commands over separate SSH invocations`() async throws {
        try await Self.withFixtureMachine { machine, fixture in
            try await machine.run("touch first.txt")
            try await machine.run("touch second.txt")

            #expect(FileManager.default.fileExists(atPath: fixture.remoteRoot.path + "/first.txt"))
            #expect(FileManager.default.fileExists(atPath: fixture.remoteRoot.path + "/second.txt"))
            #expect(try fixture.counter(named: "run-count") == 2)
        }
    }

    @Test
    func `collected output API matches swift-subprocess style`() async throws {
        try await Self.withFixtureMachine { machine, _ in
            let record = try await machine.run(
                "printf 'hello'",
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

            #expect(record.terminationStatus.isSuccess)
            #expect(record.standardOutput == "hello")
            #expect(record.standardError == "")
        }
    }

    @Test
    func `collected output callback receives command output`() async throws {
        try await Self.withFixtureMachine { machine, _ in
            try await machine.run("printf 'hello'; printf 'oops' >&2") {
                standardOutput,
                standardError in
                #expect(standardOutput == "hello")
                #expect(standardError == "oops")
                #expect(standardOutput.contains(/he.*o/))
            }
        }
    }

    @Test
    func `simple run throws when the remote command exits non-zero`() async throws {
        try await Self.withFixtureMachine { machine, _ in
            await #expect(throws: MachineError.self) {
                try await machine.run("exit 7")
            }
            return ()
        }
    }

    @Test
    func `command builder runs command`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-command-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let machine = Machine(name: "Local", workingDirectory: directory.path)
        try await machine.command("touch builder.txt").run()

        #expect(FileManager.default.fileExists(atPath: directory.path + "/builder.txt"))
    }

    @Test
    func `poll retries command until it succeeds`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-poll-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let machine = Machine(name: "Local", workingDirectory: directory.path)
        try await machine
            .command(
                """
                count=$(cat counter.txt 2>/dev/null || echo 0)
                count=$((count + 1))
                echo "$count" > counter.txt
                test "$count" -ge 3
                """
            )
            .poll(until: .success, step: .milliseconds(10), timeout: .seconds(2))
            .run()

        let count = try String(
            contentsOf: directory.appendingPathComponent("counter.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(count == "3")
    }

    @Test
    func `poll throws timeout error with timeout message`() async throws {
        let machine = Machine(name: "Local")

        await #expect(throws: MachineError.self) {
            try await machine
                .command("exit 1")
                .poll(
                    until: .success,
                    step: .milliseconds(10),
                    timeout: .milliseconds(25),
                    timeoutMessage: "command never succeeded"
                )
                .run()
        }
    }

    private static func withFixtureMachine<Result>(
        _ body: (Machine, SSHFixture) async throws -> Result
    ) async throws -> Result {
        let fixture = try SSHFixture()
        let machine = Machine(
            name: "SSH",
            ssh: "ai@example.local",
            workingDirectory: fixture.remoteRoot.path,
            sshExecutable: fixture.sshScript.path
        )

        defer { fixture.remove() }
        return try await body(machine, fixture)
    }
}

private struct SSHFixture {
    let root: URL
    let remoteRoot: URL
    let sshScript: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-ssh-" + UUID().uuidString, isDirectory: true)
        self.remoteRoot = self.root.appendingPathComponent("remote", isDirectory: true)
        self.sshScript = self.root.appendingPathComponent("fake-ssh.sh")

        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: self.remoteRoot,
            withIntermediateDirectories: true
        )

        try self.writeFakeSSHScript()
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func counter(named name: String) throws -> Int {
        let url = self.root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        let string = try String(contentsOf: url, encoding: .utf8)
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func writeFakeSSHScript() throws {
        let stateDirectory = Self.shellQuote(self.root.path)
        let contents = """
            #!/bin/bash
            set -euo pipefail

            state_dir=\(stateDirectory)
            args=()

            increment() {
              local file="$1"
              local count=0
              if [[ -f "$file" ]]; then
                count=$(<"$file")
              fi
              echo $((count + 1)) > "$file"
            }

            while (($#)); do
              case "$1" in
                -T)
                  shift
                  ;;
                -o)
                  shift 2
                  ;;
                *)
                  args+=("$1")
                  shift
                  ;;
              esac
            done

            command="${args[1]:-}"
            run_count="$state_dir/run-count"

            increment "$run_count"
            printf '%s\n' "$command" >> "$state_dir/commands.log"
            exec /bin/bash -lc "$command"
            """

        try contents.write(to: self.sshScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: self.sshScript.path
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
