import Foundation

/// Чистые преобразования PCM для записи и распознавателя (этап 3, §4.3).
public enum AudioPCM {
    private static let scale: Float = 32768

    @inline(__always)
    private static func sample(_ x: Float) -> Int16 {
        let v = (x * scale).rounded()
        if v.isNaN { return 0 }
        if v >= 32767 { return 32767 }
        if v <= -32768 { return -32768 }
        return Int16(v)
    }

    private static func data(count: Int, _ at: (Int) -> Int16) -> Data {
        var out = Data(count: count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let v = UInt16(bitPattern: at(i))
                p[2 * i] = UInt8(v & 0xFF)
                p[2 * i + 1] = UInt8(v >> 8)
            }
        }
        return out
    }

    /// clamp в диапазон Int16, x·32768, LE.
    public static func int16(fromFloat samples: UnsafeBufferPointer<Float>) -> Data {
        data(count: samples.count) { sample(samples[$0]) }
    }

    public static func int16(fromFloat samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { int16(fromFloat: $0) }
    }

    /// Среднее по каналам (SCK non-interleaved, poc/appaudio/probe/SCKCapture.swift:153-168).
    public static func monoInt16(planes: [UnsafeBufferPointer<Float>], frames: Int) -> Data {
        guard !planes.isEmpty, frames > 0 else { return Data() }
        let n = min(frames, planes.map(\.count).min() ?? 0)
        let k = Float(planes.count)
        return data(count: n) { f in
            var sum: Float = 0
            for p in planes { sum += p[f] }
            return sample(sum / k)
        }
    }

    public static func monoInt16(interleaved: UnsafeBufferPointer<Float>, channels: Int) -> Data {
        guard channels > 0 else { return Data() }
        let frames = interleaved.count / channels
        let k = Float(channels)
        return data(count: frames) { f in
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[f * channels + c] }
            return sample(sum / k)
        }
    }

    /// 0…1; пусто → 0.
    public static func rms(int16 data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var acc: Double = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let v = Int16(bitPattern: UInt16(p[2 * i]) | (UInt16(p[2 * i + 1]) << 8))
                let x = Double(v) / Double(scale)
                acc += x * x
            }
        }
        return Float((acc / Double(count)).squareRoot())
    }

    /// Равные длины (precondition).
    public static func interleave(left: Data, right: Data) -> Data {
        precondition(left.count == right.count, "interleave: дорожки разной длины")
        let frames = left.count / 2
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { raw in
            let o = raw.bindMemory(to: UInt8.self)
            left.withUnsafeBytes { l in
                right.withUnsafeBytes { r in
                    let lp = l.bindMemory(to: UInt8.self)
                    let rp = r.bindMemory(to: UInt8.self)
                    for f in 0..<frames {
                        o[4 * f] = lp[2 * f]
                        o[4 * f + 1] = lp[2 * f + 1]
                        o[4 * f + 2] = rp[2 * f]
                        o[4 * f + 3] = rp[2 * f + 1]
                    }
                }
            }
        }
        return out
    }
}
