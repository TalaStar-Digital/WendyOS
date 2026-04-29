import Foundation
import Subprocess
import Testing

@testable import WendyAgentE2E

struct MachineTests {
    @Test("parse ssh machine spec")
    func parseSSHMachineSpec() throws {
        let machine = try Machine.parse("ai@example.local:~/wendy-agent")

        #expect(machine.sshTarget == "ai@example.local")
        #expect(machine.baseDirectory == "~/wendy-agent")
        #expect(machine.description == "ai@example.local:~/wendy-agent")
    }

    @Test("reuses one persistent SSH master connection across runs")
    func reusesPersistentSSHMasterConnectionAcrossRuns() async throws {
        let fixture = try SSHFixture()
        defer { fixture.remove() }

        let machine = Machine(
            sshTarget: "ai@example.local",
            baseDirectory: fixture.remoteRoot.path,
            sshExecutable: fixture.sshScript.path,
            controlPath: fixture.controlPath
        )

        try await machine.run("touch first.txt")
        try await machine.run("touch second.txt")
        try await machine.close()

        #expect(FileManager.default.fileExists(atPath: fixture.remoteRoot.path + "/first.txt"))
        #expect(FileManager.default.fileExists(atPath: fixture.remoteRoot.path + "/second.txt"))
        #expect(try fixture.counter(named: "master-count") == 1)
        #expect(try fixture.counter(named: "run-count") == 2)
    }

    @Test("closure API streams stdout and stderr")
    func closureAPIStreamsStdoutAndStderr() async throws {
        let fixture = try SSHFixture()
        defer { fixture.remove() }

        let machine = Machine(
            sshTarget: "ai@example.local",
            baseDirectory: fixture.remoteRoot.path,
            sshExecutable: fixture.sshScript.path,
            controlPath: fixture.controlPath
        )
        defer {
            Task {
                try? await machine.close()
            }
        }

        let outcome = try await machine.run(
            "printf 'hello\\n'; printf 'oops\\n' >&2"
        ) { _, _, stdout, stderr in
            async let stdoutLines = Self.collectLines(from: stdout)
            async let stderrLines = Self.collectLines(from: stderr)
            return try await (stdoutLines, stderrLines)
        }

        #expect(outcome.terminationStatus.isSuccess)
        #expect(outcome.value.0 == ["hello"])
        #expect(outcome.value.1 == ["oops"])
    }

    @Test("collected output API matches swift-subprocess style")
    func collectedOutputAPIMatchesSwiftSubprocessStyle() async throws {
        let fixture = try SSHFixture()
        defer { fixture.remove() }

        let machine = Machine(
            sshTarget: "ai@example.local",
            baseDirectory: fixture.remoteRoot.path,
            sshExecutable: fixture.sshScript.path,
            controlPath: fixture.controlPath
        )
        defer {
            Task {
                try? await machine.close()
            }
        }

        let record = try await machine.run(
            "printf 'hello'",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput == "hello")
        #expect(record.standardError == "")
    }

    @Test("simple run throws when the remote command exits non-zero")
    func simpleRunThrowsOnNonZeroExit() async throws {
        let fixture = try SSHFixture()
        defer { fixture.remove() }

        let machine = Machine(
            sshTarget: "ai@example.local",
            baseDirectory: fixture.remoteRoot.path,
            sshExecutable: fixture.sshScript.path,
            controlPath: fixture.controlPath
        )
        defer {
            Task {
                try? await machine.close()
            }
        }

        await #expect(throws: MachineError.self) {
            try await machine.run("exit 7")
        }
    }

    private static func collectLines(from sequence: AsyncBufferSequence) async throws -> [String] {
        var lines: [String] = []
        for try await line in sequence.lines() {
            lines.append(line.trimmingCharacters(in: .newlines))
        }
        return lines
    }
}

private struct SSHFixture {
    let root: URL
    let remoteRoot: URL
    let sshScript: URL
    let controlPath: String

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-ssh-" + UUID().uuidString, isDirectory: true)
        self.remoteRoot = self.root.appendingPathComponent("remote", isDirectory: true)
        self.sshScript = self.root.appendingPathComponent("fake-ssh.sh")
        self.controlPath = self.root.appendingPathComponent("control.sock").path

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
            socket=""
            operation=""
            master=false
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
                -MNf)
                  master=true
                  shift
                  ;;
                -T)
                  shift
                  ;;
                -o)
                  if [[ "$2" == ControlPath=* ]]; then
                    socket="${2#ControlPath=}"
                  fi
                  shift 2
                  ;;
                -O)
                  operation="$2"
                  shift 2
                  ;;
                *)
                  args+=("$1")
                  shift
                  ;;
              esac
            done

            target="${args[0]:-}"
            command="${args[1]:-}"
            master_count="$state_dir/master-count"
            run_count="$state_dir/run-count"

            case "$operation" in
              check)
                if [[ -n "$socket" && -e "$socket" ]]; then
                  exit 0
                fi
                exit 255
                ;;
              exit)
                if [[ -n "$socket" ]]; then
                  rm -f "$socket"
                fi
                exit 0
                ;;
            esac

            if [[ "$master" == true ]]; then
              mkdir -p "$(dirname "$socket")"
              : > "$socket"
              increment "$master_count"
              exit 0
            fi

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
