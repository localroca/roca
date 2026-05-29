import Foundation
import RocaCore

enum AudioChunkDurationEstimator {
    static func durationMilliseconds(for chunk: AudioChunk) -> Int? {
        switch chunk.format.encoding {
        case .wav:
            wavDurationMilliseconds(data: chunk.data, descriptor: chunk.format)
        case .pcm:
            rawPCMDurationMilliseconds(byteCount: chunk.data.count, descriptor: chunk.format)
        case .mp3, .opus, .flac:
            nil
        }
    }

    private static func wavDurationMilliseconds(data: Data, descriptor: AudioDescriptor) -> Int? {
        guard data.count >= 12,
              ascii(data, offset: 0, count: 4) == "RIFF",
              ascii(data, offset: 8, count: 4) == "WAVE"
        else {
            return rawPCMDurationMilliseconds(byteCount: data.count, descriptor: descriptor)
        }

        var offset = 12
        var sampleRate = descriptor.sampleRate
        var channels = descriptor.channels
        var bitDepth = descriptor.bitDepth
        var dataByteCount: Int?

        while offset + 8 <= data.count {
            guard let chunkSize = uint32LE(data, offset: offset + 4) else {
                break
            }

            let id = ascii(data, offset: offset, count: 4)
            let bodyOffset = offset + 8
            let bodySize = Int(chunkSize)
            guard bodyOffset + bodySize <= data.count else {
                break
            }

            if id == "fmt " {
                channels = Int(uint16LE(data, offset: bodyOffset + 2) ?? UInt16(channels ?? 0))
                sampleRate = Int(uint32LE(data, offset: bodyOffset + 4) ?? UInt32(sampleRate ?? 0))
                bitDepth = Int(uint16LE(data, offset: bodyOffset + 14) ?? UInt16(bitDepth ?? 0))
            } else if id == "data" {
                dataByteCount = bodySize
            }

            offset = bodyOffset + bodySize + (bodySize % 2)
        }

        return rawPCMDurationMilliseconds(
            byteCount: dataByteCount ?? 0,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )
    }

    private static func rawPCMDurationMilliseconds(byteCount: Int, descriptor: AudioDescriptor) -> Int? {
        rawPCMDurationMilliseconds(
            byteCount: byteCount,
            sampleRate: descriptor.sampleRate,
            channels: descriptor.channels,
            bitDepth: descriptor.bitDepth
        )
    }

    private static func rawPCMDurationMilliseconds(
        byteCount: Int,
        sampleRate: Int?,
        channels: Int?,
        bitDepth: Int?
    ) -> Int? {
        guard byteCount > 0,
              let sampleRate,
              let channels,
              let bitDepth,
              sampleRate > 0,
              channels > 0,
              bitDepth > 0
        else {
            return nil
        }

        let bytesPerSecond = Double(sampleRate * channels * bitDepth) / 8.0
        guard bytesPerSecond > 0 else {
            return nil
        }
        return max(0, Int((Double(byteCount) / bytesPerSecond * 1000).rounded()))
    }

    private static func ascii(_ data: Data, offset: Int, count: Int) -> String? {
        guard offset >= 0, offset + count <= data.count else {
            return nil
        }
        return String(data: data.subdata(in: offset ..< offset + count), encoding: .ascii)
    }

    private static func uint16LE(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else {
            return nil
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
