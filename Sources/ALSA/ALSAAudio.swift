#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Represents an ALSA audio device
public struct ALSAAudioDevice: Sendable {
    public let cardIndex: Int
    public let deviceIndex: Int
    public let name: String
    public let cardName: String
    public let isCapture: Bool
    public let isPlayback: Bool

    /// ALSA device identifier for opening (e.g., "plughw:0,0")
    public var deviceId: String {
        "plughw:\(cardIndex),\(deviceIndex)"
    }

    /// Hardware device identifier (e.g., "hw:0,0")
    public var hwDeviceId: String {
        "hw:\(cardIndex),\(deviceIndex)"
    }
}

/// High-level ALSA audio interface using direct /proc/asound access for listing
/// and arecord subprocess for capture
public struct ALSAAudio: Sendable {

    public init() throws {
        // Verify /proc/asound exists
        guard FileManager.default.fileExists(atPath: "/proc/asound/cards") else {
            throw ALSAError.notAvailable
        }
    }

    /// Check if ALSA is available on this system
    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: "/proc/asound/cards")
    }

    /// Check if arecord is available for audio capture
    public static var isArecordAvailable: Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/arecord")
    }

    /// Get the initialization error if ALSA failed to load (for debugging)
    public static var initializationError: Error? {
        if isAvailable {
            return nil
        }
        return ALSAError.notAvailable
    }

    /// List all available audio devices
    public func listDevices() throws -> [ALSAAudioDevice] {
        var devices: [ALSAAudioDevice] = []

        let cards = try ALSADirect.listCards()

        for card in cards {
            for pcmDevice in card.pcmDevices {
                // Use card name as the primary name (it usually has the actual device name like "Blue Yeti")
                // Use PCM device name as secondary info if it differs from card name
                let displayName: String
                let description: String

                if card.pcmDevices.count == 1 {
                    // Single PCM device on this card - just use the card name
                    displayName = card.name
                    description = pcmDevice.name != card.name ? pcmDevice.name : ""
                } else {
                    // Multiple PCM devices - include device index for clarity
                    displayName = "\(card.name) (\(pcmDevice.name))"
                    description = ""
                }

                devices.append(ALSAAudioDevice(
                    cardIndex: card.index,
                    deviceIndex: pcmDevice.index,
                    name: displayName,
                    cardName: description,
                    isCapture: pcmDevice.isCapture,
                    isPlayback: pcmDevice.isPlayback
                ))
            }
        }

        return devices
    }

    /// Open a PCM device for capture using arecord subprocess
    public func openCapture(
        device: String = "default",
        sampleRate: UInt32 = 48000,
        channels: UInt32 = 1,
        latencyMicroseconds: UInt32 = 100000
    ) throws -> ALSACaptureStream {
        // Parse device string like "plughw:0,0" or "hw:0,0"
        var cardIndex = 0
        var deviceIndex = 0

        if device != "default" {
            // Parse "plughw:X,Y" or "hw:X,Y" format
            let parts = device.components(separatedBy: ":")
            if parts.count == 2 {
                let indices = parts[1].components(separatedBy: ",")
                if indices.count >= 1, let card = Int(indices[0]) {
                    cardIndex = card
                }
                if indices.count >= 2, let dev = Int(indices[1]) {
                    deviceIndex = dev
                }
            }
        }

        return try ALSACaptureStream(
            cardIndex: cardIndex,
            deviceIndex: deviceIndex,
            sampleRate: sampleRate,
            channels: channels
        )
    }
}

/// ALSA PCM capture stream using arecord subprocess
///
/// This type uses `@unchecked Sendable` because:
/// - The underlying process pipes are thread-safe for reads
/// - The process handle is immutable after initialization
/// - All mutable state is synchronized via the process lifecycle
public final class ALSACaptureStream: @unchecked Sendable {
    private let process: Foundation.Process
    private let pipe: Pipe
    public let cardIndex: Int
    public let deviceIndex: Int
    public let sampleRate: UInt32
    public let channels: UInt32
    private let bytesPerFrame: Int

    init(
        cardIndex: Int,
        deviceIndex: Int,
        sampleRate: UInt32,
        channels: UInt32
    ) throws {
        self.cardIndex = cardIndex
        self.deviceIndex = deviceIndex
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytesPerFrame = Int(channels) * 2  // 16-bit = 2 bytes per sample

        // Check if arecord is available
        guard ALSAAudio.isArecordAvailable else {
            throw ALSAError.setParamsFailed(
                "arecord not found. Please install alsa-utils package."
            )
        }

        // Create pipe for reading audio data
        self.pipe = Pipe()

        // Set up arecord process
        // arecord -D plughw:0,0 -f S16_LE -r 48000 -c 1 -t raw -
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arecord")
        process.arguments = [
            "-D", "plughw:\(cardIndex),\(deviceIndex)",
            "-f", "S16_LE",           // 16-bit signed little-endian
            "-r", "\(sampleRate)",    // Sample rate
            "-c", "\(channels)",      // Channels
            "-t", "raw",              // Raw PCM output (no WAV header)
            "--buffer-size=4096",     // Buffer size in frames
            "-"                       // Output to stdout
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        self.process = process

        do {
            try process.run()
        } catch {
            throw ALSAError.deviceOpenFailed("Failed to start arecord: \(error)")
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    /// Read audio frames into a buffer
    /// Returns the number of frames read, or throws on error
    public func read(into buffer: UnsafeMutableRawPointer, frameCount: Int) throws -> Int {
        let bufferSize = frameCount * bytesPerFrame
        let data = pipe.fileHandleForReading.readData(ofLength: bufferSize)

        guard !data.isEmpty else {
            if !process.isRunning {
                throw ALSAError.readFailed("arecord process terminated unexpectedly")
            }
            return 0
        }

        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return data.count / bytesPerFrame
    }

    /// Read audio data and return as Data
    public func readData(frameCount: Int) throws -> Data {
        let bufferSize = frameCount * bytesPerFrame
        let data = pipe.fileHandleForReading.readData(ofLength: bufferSize)

        guard !data.isEmpty else {
            if !process.isRunning {
                throw ALSAError.readFailed("arecord process terminated unexpectedly")
            }
            return Data()
        }

        return data
    }

    /// Stop the capture
    public func stop() {
        if process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - Streaming API using proper patterns

extension ALSACaptureStream {
    /// Stream audio data using structured concurrency
    ///
    /// Usage:
    /// ```swift
    /// try await stream.withAudioData(framesPerChunk: 2400) { data in
    ///     // Process audio data
    /// }
    /// ```
    public func withAudioData(
        framesPerChunk: Int = 2400,
        handler: @Sendable (Data) async throws -> Void
    ) async throws {
        while !Task.isCancelled {
            let data = try readData(frameCount: framesPerChunk)
            if !data.isEmpty {
                try await handler(data)
            } else {
                // No data available, check if process is still running
                if !process.isRunning {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        stop()
    }
}
#endif
