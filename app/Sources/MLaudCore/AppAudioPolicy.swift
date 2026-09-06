import Foundation

/// Решения о захвате звука приложения без железа (образец — `RebuildPolicy` в AudioCapture.swift).
public enum AppAudioPolicy {
    public enum StartFailure: Equatable { case needsRestart, noContent, other(Int) }

    /// SCK −3801 — согласие на «Запись экрана» уже дано, нужен перезапуск (poc/appaudio/RESULT.md:78,121-123).
    public static let needsRestartCode = -3801

    public static func classify(errorCode: Int) -> StartFailure {
        errorCode == needsRestartCode ? .needsRestart : .other(errorCode)
    }

    public enum AfterOutputChange: Equatable { case keep, restart }

    /// Буферов не было или они встали дольше stallTimeout → пересобрать захват.
    public static func afterOutputChange(lastBufferAge: TimeInterval?, stallTimeout: TimeInterval = 2) -> AfterOutputChange {
        guard let lastBufferAge, lastBufferAge <= stallTimeout else { return .restart }
        return .keep
    }

    /// Буферы идут, но RMS ниже порога дольше silenceAfter → .silent(since:); иначе .flowing.
    public static func health(rms: Float, silentFor: TimeInterval, threshold: Float = 0.006, silenceAfter: TimeInterval = 10) -> ChannelHealth {
        if rms < threshold, silentFor >= silenceAfter { return .silent(since: silentFor) }
        return .flowing
    }
}
