import AppKit
import MLaudCore
import NitiUI
import SwiftUI

extension NitiTrailing.Tone {
    var color: Color {
        switch self {
        case .accent: return Niti.Colors.accent
        case .success: return Niti.Colors.success
        case .danger: return Niti.Colors.danger
        }
    }
}

extension NitiTrailing {
    var navTrailing: NitiNavItem.Trailing {
        switch self {
        case .none: return .none
        case .badge(let n): return .badge(n)
        case .text(let s): return .text(s)
        case .dot(let tone): return .dot(tone.color)
        }
    }
}

extension OverviewState.Tone {
    var pill: NitiStatusPill.Tone {
        switch self {
        case .neutral: return .neutral
        case .accent: return .accent
        case .success: return .success
        case .warning: return .warning
        case .danger: return .danger
        case .muted: return .muted
        }
    }
}

/// Каркас экрана: заголовок с действиями справа, содержимое с отступами Niti. По умолчанию
/// содержимое прокручивается целиком; `scrolls: false` — для экранов со своими списками
/// («Голоса»: записи слева, карточки справа), которым нужна вся высота.
struct Screen<Content: View, Trailing: View>: View {
    private let title: String
    private let scrolls: Bool
    private let trailing: Trailing
    private let content: Content

    init(_ title: String, scrolls: Bool = true, @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.scrolls = scrolls
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Niti.Spacing.s3) {
                Text(title)
                    .font(Niti.Typography.xl)
                    .fontWeight(Niti.Weight.semibold)
                    .foregroundStyle(Niti.Colors.text)
                Spacer()
                trailing
            }
            .padding(.horizontal, Niti.Spacing.s5)
            .padding(.top, Niti.Spacing.s5)
            .padding(.bottom, Niti.Spacing.s4)
            if scrolls {
                ScrollView {
                    inner
                }
            } else {
                inner
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Niti.Colors.bg)
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s4) {
            content
        }
        .padding(.horizontal, Niti.Spacing.s5)
        .padding(.bottom, Niti.Spacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Screen where Trailing == EmptyView {
    init(_ title: String, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, scrolls: scrolls, content: content) { EmptyView() }
    }
}

/// Блок с заголовком на карточке Niti.
struct Panel<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NitiCard {
            VStack(alignment: .leading, spacing: Niti.Spacing.s3) {
                if let title {
                    Text(title)
                        .font(Niti.Typography.lg)
                        .foregroundStyle(Niti.Colors.text)
                }
                content
            }
        }
    }
}

/// Серый поясняющий текст под контролом или внутри блока.
struct Hint: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Niti.Typography.sm)
            .foregroundStyle(Niti.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Поле «нажми сочетание» из настроек — тот же `HotKeyRecorder`, обёрнутый для SwiftUI.
struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var combo: HotKey.Combo

    func makeNSView(context: Context) -> HotKeyRecorder {
        let view = HotKeyRecorder(combo: combo)
        view.onChange = { combo = $0 }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorder, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HotKeyRecorder, context: Context) -> CGSize? {
        CGSize(width: 160, height: 24)
    }
}

/// Форматы дат и длительностей для списков.
enum Format {
    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f
    }()

    static func dayTime(_ date: Date) -> String { dayTime.string(from: date) }
    static func full(_ date: Date) -> String { full.string(from: date) }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) с" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) мин" }
        return String(format: "%d ч %02d мин", minutes / 60, minutes % 60)
    }

    static func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Имя периода `YYYY-MM` — по-русски; иное имя каталога остаётся как есть.
    static func period(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month) else { return name }
        let names = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август",
                     "сентябрь", "октябрь", "ноябрь", "декабрь"]
        return "\(names[month - 1]) \(year)"
    }
}
