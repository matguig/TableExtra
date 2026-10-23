import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Layout shared by the transfer sheets: header (icon tile, title, subtitle, accessory), padded content,
/// footer with a hairline above and the buttons aligned right. Sizes are flexible so the sheet always fits its window.
struct TransferSheet<Accessory: View, Content: View, FooterLeading: View, FooterTrailing: View>: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var accessory: Accessory
    var content: Content
    var footerLeading: FooterLeading
    var footerTrailing: FooterTrailing

    init(_ title: String, subtitle: String, systemImage: String, tint: Color = .accentColor,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content,
         @ViewBuilder footerLeading: () -> FooterLeading = { EmptyView() },
         @ViewBuilder footer: () -> FooterTrailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
        self.footerLeading = footerLeading()
        self.footerTrailing = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitleBar(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint) { accessory }
            VStack(alignment: .leading, spacing: DS.Space.xl) { content }
                .padding(.horizontal, DS.Space.xl + DS.Space.xs)
                .padding(.vertical, DS.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            SheetFooter { footerLeading } trailing: { footerTrailing }
        }
    }
}

/// Sheet title row: tinted icon tile, title and one-line subtitle, optional trailing accessory.
struct SheetTitleBar<Accessory: View>: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color = .accentColor
    var accessory: Accessory

    init(title: String, subtitle: String, systemImage: String, tint: Color = .accentColor, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: DS.Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m + 1, style: .continuous).fill(tint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typo.title).lineLimit(1)
                Text(subtitle).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.l)
            accessory
        }
        .padding(.horizontal, DS.Space.xl + DS.Space.xs)
        .frame(height: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.separator).frame(height: 0.5) }
    }
}

/// Bottom button row of a sheet: status on the left, actions on the right, hairline above.
struct SheetFooter<Leading: View, Trailing: View>: View {
    var leading: Leading
    var trailing: Trailing

    init(@ViewBuilder leading: () -> Leading = { EmptyView() }, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            leading
                .font(DS.Typo.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.l)
            trailing
                .fixedSize()
        }
        .controlSize(.regular)
        .padding(.horizontal, DS.Space.xl + DS.Space.xs)
        .frame(height: 52)
        .background(DS.Palette.bar)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.separator).frame(height: 0.5) }
    }
}

/// Eyebrow label + content, the grouping unit inside the transfer sheets.
struct SheetSection<Accessory: View, Content: View>: View {
    var title: String
    var count: Int?
    var accessory: Accessory
    var content: Content

    init(_ title: String, count: Int? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionLabel(title, count: count) { accessory }
                .frame(minHeight: 18)
            content
        }
    }
}

/// Recessed, bordered box for monospaced previews, logs and lists inside a sheet.
struct InsetBox<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }
}

/// Small secondary help text under a control group.
struct HintText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Lines streamed from pg_dump / pg_restore / psql.
@MainActor
final class ProcessLog: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    @Published private(set) var lines: [Line] = []
    private let limit = 5_000

    func append(_ text: String, isError: Bool = false) {
        let flagged = isError || text.contains("ERROR") || text.contains("error:") || text.contains("FATAL")
        lines.append(Line(id: (lines.last?.id ?? -1) + 1, text: text, isError: flagged))
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func clear() { lines = [] }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

struct ProcessLogView: View {
    @ObservedObject var log: ProcessLog

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(log.lines) { line in
                        Text(line.text)
                            .font(DS.Typo.monoSmall)
                            .foregroundStyle(line.isError ? Color(nsColor: NSColor.systemRed.readableText()) : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(DS.Space.m)
            }
            .overlay {
                if log.lines.isEmpty {
                    Text("Output from the tool appears here").font(DS.Typo.callout).foregroundStyle(.tertiary)
                }
            }
            .onChange(of: log.lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .modifier(InsetBoxModifier())
    }
}

struct InsetBoxModifier: ViewModifier {
    func body(content: Content) -> some View {
        InsetBox { content }
    }
}

/// "Elapsed 1m 03s", refreshed every second while running.
struct ElapsedText: View {
    var start: Date?
    var end: Date?

    var body: some View {
        if let start {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Label("\(Fmt.duration((end ?? context.date).timeIntervalSince(start)))", systemImage: "clock")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Elapsed time")
            }
        }
    }
}

@MainActor
enum Panels {
    static func chooseFolder(prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Files, or folders too when `allowDirectories` (pg_dump directory archives).
    static func chooseFile(allowDirectories: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowDirectories
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Size of a file, or of every file inside a folder.
func diskSize(_ url: URL) -> Int64? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
    if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value }
    guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
    var total: Int64 = 0
    for case let f as URL in files {
        total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}
