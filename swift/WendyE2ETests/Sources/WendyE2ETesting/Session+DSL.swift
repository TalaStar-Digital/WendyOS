extension WendyE2ESession {
    public func command(_ command: String) -> WendyE2ESessionCommand {
        WendyE2ESessionCommand(session: self, command: command)
    }
}
