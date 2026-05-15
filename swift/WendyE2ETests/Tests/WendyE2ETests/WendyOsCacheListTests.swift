import Subprocess
import Testing
import WendyE2ETesting

@Suite
struct `'wendy os cache list'` {
    let scenario = CLIAndAgentScenario()

    /**
     Displays usage for `wendy os cache list`. The output includes the command
     synopsis, local flags, inherited global flags, and concise
     descriptions. Help exits successfully, writes to stdout, emits no
     stderr, and leaves configuration, cache, project, cloud, and device
     state untouched.
     */
    @Test
    func `prints command help`() async throws {
        try await self.scenario.run { cli, _ in
            try await cli.sh("wendy os cache list --help") {
                terminationStatus,
                standardOutput,
                standardError in

                #expect(terminationStatus.isSuccess)
                #expect(standardOutput.contains("List cached OS images"))
                #expect(standardOutput.contains("Usage:"))
                #expect(standardOutput.contains("wendy os cache list [flags]"))
                #expect(standardOutput.contains("--help"))
                #expect(standardOutput.contains("--device"))
                #expect(standardOutput.contains("--json"))
                #expect(standardError == "")
            }
        }
    }

    /**
     Shows entries in the OS image cache with stable columns for name, type,
     size, and last-updated metadata. An empty cache is reported as an empty
     successful result, not an error.
     */
    @Test
    func `lists cached items in a readable table`() async throws {
        try await self.scenario.run { cli, _ in
            try await cli.sh("wendy os cache list") {
                terminationStatus,
                standardOutput,
                standardError in

                #expect(terminationStatus.isSuccess)
                #expect(standardOutput == "No cached OS images.\n")
                #expect(standardError == "")
            }
        }
    }

    /**
     Only files owned by Wendy cache management appear in the listing.
     Configuration files, credentials, and project-local artifacts are not
     scanned or displayed.
     */
    @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
    func `ignores unrelated files outside the cache root`() async throws {
        // TODO: implement.
    }

    /**
     Unreadable or malformed cache metadata produces a diagnostic that
     identifies the affected entry while preserving the rest of the cache.
     */
    @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
    func `reports unreadable cache metadata clearly`() async throws {
        // TODO: implement.
    }

    /**
     With `--json`, emits one JSON object or array with machine-readable
     cache entries and byte counts. JSON mode emits no table formatting and
     no stderr on success.
     */
    @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
    func `prints JSON cache entries for automation`() async throws {
        // TODO: implement.
    }

    /**
     Accepts only the documented arguments and flags for `wendy os cache list`.
     Extra positional arguments or unknown flags produce a usage diagnostic
     on stderr, return a failure status, emit no success output, and leave
     existing state unchanged.
     */
    @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
    func `rejects undocumented arguments and flags`() async throws {
        // TODO: implement.
    }
}
