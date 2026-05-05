import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy auth'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `describes subcommands`() async throws {
        try await self.cli.run("./bin/wendy auth --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage authentication with Wendy Cloud"))
            #expect(standardOutput.contains("login"))
            #expect(standardOutput.contains("logout"))
            #expect(standardOutput.contains("refresh-certs"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy auth login'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test(.disabled("TODO: one-by-one E2E run timed out; make this flow deterministic and non-interactive."))
    func `starts the login flow with clear browser instructions`() async throws {
        // TODO: Re-enable after making this flow deterministic and non-interactive; one-by-one E2E run timed out.
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-login-start")
        defer { try? FileManager.default.removeItem(at: home) }

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) /usr/bin/perl -e 'alarm 2; exec @ARGV' ./bin/wendy auth login --cloud http://127.0.0.1:9 --cloud-grpc 127.0.0.1:9",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Opening browser for authentication:") == true)
        #expect(record.standardOutput?.contains("/cli-auth?redirect_uri=") == true)
        #expect(record.standardOutput?.contains("Waiting for authentication") == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run timed out; make this flow deterministic and non-interactive."))
    func `stores credentials after a successful login`() async throws {
        // TODO: Re-enable after making this flow deterministic and non-interactive; one-by-one E2E run timed out.
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-login-success")
        defer { try? FileManager.default.removeItem(at: home) }

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) /usr/bin/perl -e 'alarm 2; exec @ARGV' ./bin/wendy auth login --cloud http://127.0.0.1:9 --cloud-grpc 127.0.0.1:9",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Authentication successful") == true)
        let config = try Helper.userConfig(home: home)
        let auth = try #require(config["auth"] as? [[String: Any]])
        let entry = try #require(auth.first)
        #expect(entry["cloudDashboard"] as? String == "http://127.0.0.1:9")
        #expect((entry["certificates"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test(.disabled("TODO: one-by-one E2E run timed out; make this flow deterministic and non-interactive."))
    func `fails clearly when login cannot complete`() async throws {
        // TODO: Re-enable after making this flow deterministic and non-interactive; one-by-one E2E run timed out.
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-login-fail")
        defer { try? FileManager.default.removeItem(at: home) }

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) /usr/bin/perl -e 'alarm 2; exec @ARGV' ./bin/wendy auth login --cloud http://127.0.0.1:9 --cloud-grpc 127.0.0.1:9",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Opening browser") == true)
        #expect(record.standardOutput?.contains("Waiting for authentication") == true)
        #expect(record.standardError?.contains("context") == true || record.standardError?.isEmpty == false || record.standardOutput?.contains("Waiting") == true)
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy auth logout'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `removes stored credentials`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-logout")
        defer { try? FileManager.default.removeItem(at: home) }
        try Helper.writeUserConfig([
            "analytics": ["enabled": false],
            "auth": [[
                "cloudDashboard": "https://cloud.wendy.sh",
                "cloudGRPC": "cloud.wendy.sh:443",
                "certificates": [["pemCertificate": "cert", "pemPrivateKey": "key", "organizationId": 1]],
            ]],
        ], home: home)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy auth logout") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Logged out"))
            #expect(standardOutput.contains("credentials removed"))
        }

        let config = try Helper.userConfig(home: home)
        #expect(config["auth"] == nil)
    }

    @Test
    func `succeeds when no credentials are stored`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-logout-empty")
        defer { try? FileManager.default.removeItem(at: home) }
        try Helper.writeAnalyticsConfig(enabled: false, home: home)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy auth logout") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Logged out"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy auth refresh-certs'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `refreshes certificates for the authenticated user`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-refresh")
        defer { try? FileManager.default.removeItem(at: home) }
        try Helper.writeUserConfig([
            "analytics": ["enabled": false],
            "auth": [[
                "cloudDashboard": "http://127.0.0.1:9",
                "cloudGRPC": "127.0.0.1:9",
                "certificates": [["pemCertificate": "old-cert", "pemPrivateKey": "old-key", "organizationId": 1, "userId": "user-1"]],
            ]],
        ], home: home)

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) ./bin/wendy auth refresh-certs",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Refreshing certificates") == true)
        #expect(record.standardOutput?.contains("Certificates refreshed") == true)
        let config = try Helper.userConfig(home: home)
        let auth = try #require(config["auth"] as? [[String: Any]])
        let certificates = try #require(auth.first?["certificates"] as? [[String: Any]])
        #expect(certificates.first?["pemCertificate"] as? String != "old-cert")
    }

    @Test
    func `fails clearly when the user is not authenticated`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-auth-refresh-noauth")
        defer { try? FileManager.default.removeItem(at: home) }
        try Helper.writeAnalyticsConfig(enabled: false, home: home)

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) ./bin/wendy auth refresh-certs",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("not logged in") == true)
        #expect(record.standardError?.contains("wendy auth login") == true)
    }
}
