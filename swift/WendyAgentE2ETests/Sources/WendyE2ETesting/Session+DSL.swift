extension Session {
    public func command(_ command: String) -> SessionCommand {
        SessionCommand(session: self, command: command)
    }
}
