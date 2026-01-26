import Foundation

#if os(Linux)
    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #endif

    /// Direct ALSA device access through /dev/snd/ without libasound
    /// This works with statically linked binaries where dlopen isn't available
    final class ALSADirect: @unchecked Sendable {

        /// List available PCM devices by scanning /proc/asound
        static func listCards() throws -> [SoundCard] {
            var cards: [SoundCard] = []

            // Read /proc/asound/cards for card list
            let cardsPath = "/proc/asound/cards"
            guard let cardsData = FileManager.default.contents(atPath: cardsPath),
                let cardsContent = String(data: cardsData, encoding: .utf8)
            else {
                return cards
            }

            // Parse cards file format:
            //  0 [tegrahda       ]: tegra-hda - NVIDIA Jetson AGX Orin HDA
            //                       NVIDIA Jetson AGX Orin HDA at 0x3518000 irq 65
            let lines = cardsContent.components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                let line = lines[i]
                // Match lines starting with card number
                if let match = line.range(
                    of: #"^\s*(\d+)\s+\[([^\]]+)\]:\s+(\S+)\s+-\s+(.+)$"#,
                    options: .regularExpression
                ) {
                    let fullMatch = String(line[match])
                    // Extract card number
                    if let numRange = line.range(of: #"^\s*(\d+)"#, options: .regularExpression),
                        let cardNum = Int(line[numRange].trimmingCharacters(in: .whitespaces))
                    {

                        // Extract card ID (in brackets)
                        var cardId = "card\(cardNum)"
                        if let idStart = line.firstIndex(of: "["),
                            let idEnd = line.firstIndex(of: "]")
                        {
                            cardId = String(line[line.index(after: idStart)..<idEnd])
                                .trimmingCharacters(in: .whitespaces)
                        }

                        // Extract card name (after the dash)
                        var cardName = cardId
                        if let dashRange = line.range(of: " - ") {
                            cardName = String(line[dashRange.upperBound...]).trimmingCharacters(
                                in: .whitespaces
                            )
                        }

                        // Get PCM devices for this card
                        let pcmDevices = try listPCMDevices(cardIndex: cardNum)

                        cards.append(
                            SoundCard(
                                index: cardNum,
                                id: cardId,
                                name: cardName,
                                pcmDevices: pcmDevices
                            )
                        )
                    }
                }
                i += 1
            }

            return cards
        }

        /// List PCM devices for a specific card
        private static func listPCMDevices(cardIndex: Int) throws -> [PCMDevice] {
            var devices: [PCMDevice] = []

            let pcmPath = "/proc/asound/card\(cardIndex)/pcm"
            let fm = FileManager.default

            // Check if pcm directory exists
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: "/proc/asound/card\(cardIndex)", isDirectory: &isDir),
                isDir.boolValue
            else {
                return devices
            }

            // List pcm devices - they appear as pcm*p (playback) and pcm*c (capture)
            // in /proc/asound/card0/
            if let contents = try? fm.contentsOfDirectory(atPath: "/proc/asound/card\(cardIndex)") {
                for item in contents {
                    // Match pcm[0-9]+[pc]
                    if item.hasPrefix("pcm") && (item.hasSuffix("p") || item.hasSuffix("c")) {
                        let isCapture = item.hasSuffix("c")
                        let deviceNumStr = item.dropFirst(3).dropLast(1)
                        if let deviceNum = Int(deviceNumStr) {
                            // Check if we already have this device number
                            if let existingIdx = devices.firstIndex(where: { $0.index == deviceNum }
                            ) {
                                // Update existing device
                                if isCapture {
                                    devices[existingIdx].isCapture = true
                                } else {
                                    devices[existingIdx].isPlayback = true
                                }
                            } else {
                                // Read device info
                                let infoPath = "/proc/asound/card\(cardIndex)/\(item)/info"
                                var deviceName = "PCM \(deviceNum)"

                                if let infoData = fm.contents(atPath: infoPath),
                                    let infoContent = String(data: infoData, encoding: .utf8)
                                {
                                    // Parse info file for name
                                    for line in infoContent.components(separatedBy: "\n") {
                                        if line.hasPrefix("name:") {
                                            deviceName = String(line.dropFirst(5))
                                                .trimmingCharacters(in: .whitespaces)
                                            break
                                        }
                                    }
                                }

                                devices.append(
                                    PCMDevice(
                                        index: deviceNum,
                                        name: deviceName,
                                        isCapture: isCapture,
                                        isPlayback: !isCapture
                                    )
                                )
                            }
                        }
                    }
                }
            }

            return devices.sorted { $0.index < $1.index }
        }

        struct SoundCard: Sendable {
            let index: Int
            let id: String
            let name: String
            let pcmDevices: [PCMDevice]
        }

        struct PCMDevice: Sendable {
            let index: Int
            let name: String
            var isCapture: Bool
            var isPlayback: Bool
        }
    }

    // MARK: - PCM Device Handle for direct access

    /// Direct PCM capture using /dev/snd/pcmC*D*c device files
    final class DirectPCMCapture: @unchecked Sendable {
        private let fd: Int32
        let cardIndex: Int
        let deviceIndex: Int
        let sampleRate: UInt32
        let channels: UInt32
        private let bytesPerFrame: Int

        init(cardIndex: Int, deviceIndex: Int, sampleRate: UInt32, channels: UInt32) throws {
            self.cardIndex = cardIndex
            self.deviceIndex = deviceIndex
            self.sampleRate = sampleRate
            self.channels = channels
            self.bytesPerFrame = Int(channels) * 2  // 16-bit samples

            // Open the capture device
            let devicePath = "/dev/snd/pcmC\(cardIndex)D\(deviceIndex)c"

            self.fd = open(devicePath, O_RDONLY)
            guard fd >= 0 else {
                throw ALSAError.deviceOpenFailed(
                    "Cannot open \(devicePath): \(String(cString: strerror(errno)))"
                )
            }

            // Configure the device using ioctl
            // This requires setting up hw_params structure
            // For now, we'll try a simpler approach
        }

        deinit {
            if fd >= 0 {
                close(fd)
            }
        }

        /// Read audio frames
        func read(frameCount: Int) throws -> Data {
            let bufferSize = frameCount * bytesPerFrame
            var buffer = Data(count: bufferSize)

            let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                let result = Foundation.read(fd, ptr.baseAddress!, bufferSize)
                return result
            }

            if bytesRead < 0 {
                throw ALSAError.readFailed(String(cString: strerror(errno)))
            }

            if bytesRead < bufferSize {
                buffer = buffer.prefix(bytesRead)
            }

            return Data(buffer)
        }
    }
#endif

/// Errors that can occur during ALSA operations
public enum ALSAError: Error, LocalizedError {
    case libraryNotFound(String)
    case symbolNotFound(String)
    case deviceOpenFailed(String)
    case setParamsFailed(String)
    case readFailed(String)
    case noDevicesFound
    case notAvailable

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound(let msg): return "ALSA library not found: \(msg)"
        case .symbolNotFound(let name): return "ALSA symbol not found: \(name)"
        case .deviceOpenFailed(let msg): return "Failed to open audio device: \(msg)"
        case .setParamsFailed(let msg): return "Failed to set audio parameters: \(msg)"
        case .readFailed(let msg): return "Failed to read audio: \(msg)"
        case .noDevicesFound: return "No audio devices found"
        case .notAvailable: return "ALSA is not available on this system"
        }
    }
}
