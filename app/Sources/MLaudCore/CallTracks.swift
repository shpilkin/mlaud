import Foundation

/// Выравнивание дорожек по времени звонка и сборка стерео (D13, инвариант сторожа §2.4).
public final class CallTracks {
    public let sampleRate: Int
    public let tolerance: TimeInterval

    private var queue: [CallChannel: Data] = [.me: Data(), .them: Data()]
    private var pushed: [CallChannel: Int] = [.me: 0, .them: 0]
    private var head: [CallChannel: Int] = [.me: 0, .them: 0]

    public init(sampleRate: Int = 16000, tolerance: TimeInterval = 0.5) {
        self.sampleRate = sampleRate
        self.tolerance = tolerance
    }

    /// pcm с тишиной спереди, если дорожка отстала от времени звонка больше tolerance
    /// (первый кусок канала после старта, дыра после пересборки микрофона). Возвращённое — и в запись, и в распознаватель.
    public func align(_ ch: CallChannel, pcm: Data, at elapsed: TimeInterval) -> Data {
        let headSec = Double(head[ch, default: 0]) / Double(sampleRate)
        let gap = elapsed - headSec
        var out: Data
        if gap > tolerance {
            let fill = Int((gap * Double(sampleRate)).rounded())
            out = Data(count: fill * 2)
            out.append(pcm)
        } else {
            out = pcm
        }
        head[ch, default: 0] += out.count / 2
        return out
    }

    /// Тишина для дорожки, которая отстала от времени звонка больше tolerance и не шлёт куски
    /// (приложение не выбрано, SCK упал, микрофон умер): нули от головы до `elapsed − tolerance`,
    /// пусто — если дорожка не отстаёт. Возвращённое — в push и в распознаватель, как результат align;
    /// голова сдвигается, так что следующий настоящий кусок не получит двойной заливки.
    public func catchUp(_ ch: CallChannel, to elapsed: TimeInterval) -> Data {
        let target = Int(((elapsed - tolerance) * Double(sampleRate)).rounded())
        let behind = target - head[ch, default: 0]
        guard behind > 0 else { return Data() }
        head[ch, default: 0] += behind
        return Data(count: behind * 2)
    }

    /// Положить выровненный кусок; вернуть готовые interleaved-кадры (L = me, R = them), сколько есть в обеих очередях.
    public func push(_ ch: CallChannel, pcm: Data) -> Data {
        queue[ch, default: Data()].append(pcm)
        pushed[ch, default: 0] += pcm.count / 2
        return drain(frames: min(queue[.me]!.count, queue[.them]!.count) / 2)
    }

    /// Конец: короткую дорожку дополнить нулями до длинной; вернуть остаток.
    public func finish() -> Data {
        let longest = max(queue[.me]!.count, queue[.them]!.count)
        for ch in CallChannel.allCases where queue[ch]!.count < longest {
            queue[ch]!.append(Data(count: longest - queue[ch]!.count))
        }
        return drain(frames: longest / 2)
    }

    /// Отдано в push.
    public func samples(_ ch: CallChannel) -> Int {
        pushed[ch, default: 0]
    }

    private func drain(frames: Int) -> Data {
        guard frames > 0 else { return Data() }
        let bytes = frames * 2
        let left = queue[.me]!.prefix(bytes)
        let right = queue[.them]!.prefix(bytes)
        let out = AudioPCM.interleave(left: Data(left), right: Data(right))
        queue[.me] = Data(queue[.me]!.dropFirst(bytes))
        queue[.them] = Data(queue[.them]!.dropFirst(bytes))
        return out
    }
}
