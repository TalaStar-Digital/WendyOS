import Subprocess

public enum MachineError: Error {
    case commandFailed(machine: String, command: String, terminationStatus: TerminationStatus)
    case pollTimedOut(
        machine: String,
        command: String,
        condition: String,
        timeout: Duration,
        lastTerminationStatus: TerminationStatus?,
        message: String?
    )
}

// MARK: - CustomStringConvertible

extension MachineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .commandFailed(let machine, let command, let terminationStatus):
            return "Command failed on \(machine) with \(terminationStatus): \(command)"
        case .pollTimedOut(
            let machine,
            let command,
            let condition,
            let timeout,
            let lastTerminationStatus,
            let message
        ):
            let prefix = message.map { "\($0): " } ?? ""
            let lastStatus = lastTerminationStatus.map(String.init(describing:)) ?? "<none>"
            return "\(prefix)Command on \(machine) did not reach \(condition) within \(timeout)"
                + " (last status: \(lastStatus)): \(command)"
        }
    }
}
