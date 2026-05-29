import Foundation

enum KokoroWAVWriter {
    static let sampleRate = 24_000
    static let channels = 1
    static let bitDepth = 16

    static func encode(samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clipped = min(max(sample, -1.0), 1.0)
            let value = Int16(clipped * Float(Int16.max))
            pcm.appendLittleEndian(value)
        }

        let byteRate = sampleRate * channels * bitDepth / 8
        let blockAlign = channels * bitDepth / 8
        let dataSize = UInt32(pcm.count)
        let riffSize = UInt32(36 + pcm.count)

        var data = Data(capacity: 44 + pcm.count)
        data.appendASCII("RIFF")
        data.appendLittleEndian(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(bitDepth))
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
