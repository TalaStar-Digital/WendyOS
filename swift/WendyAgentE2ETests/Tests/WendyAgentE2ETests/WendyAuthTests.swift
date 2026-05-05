import Testing

@Suite(.serialized)
struct `wendy auth` {
    @Test
    func `describes authentication subcommands`() async throws {
        // TODO: implement.
    }
}

@Suite(.serialized)
struct `wendy auth login` {
    @Test
    func `starts the login flow with clear browser instructions`() async throws {
        // TODO: implement.
    }

    @Test
    func `stores credentials after a successful login`() async throws {
        // TODO: implement.
    }

    @Test
    func `fails clearly when login cannot complete`() async throws {
        // TODO: implement.
    }
}

@Suite(.serialized)
struct `wendy auth logout` {
    @Test
    func `removes stored credentials`() async throws {
        // TODO: implement.
    }

    @Test
    func `succeeds when no credentials are stored`() async throws {
        // TODO: implement.
    }
}

@Suite(.serialized)
struct `wendy auth refresh-certs` {
    @Test
    func `refreshes certificates for the authenticated user`() async throws {
        // TODO: implement.
    }

    @Test
    func `fails clearly when the user is not authenticated`() async throws {
        // TODO: implement.
    }
}
