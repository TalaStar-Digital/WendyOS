import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `CLI basics` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `'wendy --help' describes the top-level command groups`() async throws {
        // TODO: implement
    }

    @Test
    func `'wendy --version' prints the CLI version`() async throws {
        // TODO: implement
    }

    @Test
    func `'wendy info' prints CLI and system information`() async throws {
        // TODO: implement
    }
}
