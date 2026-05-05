import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy completion'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `describes supported shells`() async throws {
        try await self.cli.run("./bin/wendy completion --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Generate the autocompletion script"))
            #expect(standardOutput.contains("bash"))
            #expect(standardOutput.contains("fish"))
            #expect(standardOutput.contains("powershell"))
            #expect(standardOutput.contains("zsh"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy completion bash'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `prints a bash completion script`() async throws {
        try await self.cli.run("./bin/wendy completion bash") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.hasPrefix("# bash completion V2 for wendy"))
            #expect(standardOutput.contains("__wendy_get_completion_results"))
            #expect(standardOutput.contains("complete -o default -F __start_wendy wendy"))
        }
    }

    @Test
    func `does not print diagnostics with the script`() async throws {
        try await self.cli.run("./bin/wendy completion bash") { _, standardError in
            #expect(standardError.isEmpty)
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy completion fish'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `prints a fish completion script`() async throws {
        try await self.cli.run("./bin/wendy completion fish") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.hasPrefix("# fish completion for wendy"))
            #expect(standardOutput.contains("function __wendy_perform_completion"))
            #expect(standardOutput.contains("complete -c wendy"))
        }
    }

    @Test
    func `does not print diagnostics with the script`() async throws {
        try await self.cli.run("./bin/wendy completion fish") { _, standardError in
            #expect(standardError.isEmpty)
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy completion powershell'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `prints a PowerShell completion script`() async throws {
        try await self.cli.run("./bin/wendy completion powershell") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.hasPrefix("# powershell completion for wendy"))
            #expect(standardOutput.contains("__wendyCompleterBlock"))
            #expect(standardOutput.contains("Register-ArgumentCompleter"))
        }
    }

    @Test
    func `does not print diagnostics with the script`() async throws {
        try await self.cli.run("./bin/wendy completion powershell") { _, standardError in
            #expect(standardError.isEmpty)
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy completion zsh'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `prints a zsh completion script`() async throws {
        try await self.cli.run("./bin/wendy completion zsh") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.hasPrefix("#compdef wendy"))
            #expect(standardOutput.contains("# zsh completion for wendy"))
            #expect(standardOutput.contains("compdef _wendy wendy"))
        }
    }

    @Test
    func `does not print diagnostics with the script`() async throws {
        try await self.cli.run("./bin/wendy completion zsh") { _, standardError in
            #expect(standardError.isEmpty)
        }
    }
}
