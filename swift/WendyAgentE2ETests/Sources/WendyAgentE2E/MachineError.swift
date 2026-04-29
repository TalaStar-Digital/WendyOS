import Subprocess

public enum MachineError: Error {
    case commandFailed(machine: String, command: String, terminationStatus: TerminationStatus)
}

// MARK: - CustomStringConvertible

extension MachineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .commandFailed(let machine, let command, let terminationStatus):
            return "Command failed on \(machine) with \(terminationStatus): \(command)"
        }
    }
}
