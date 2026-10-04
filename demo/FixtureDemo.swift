// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic host only. No Steam engine, accounts, network or game files.
import ActivityKit
import SwiftUI
import UIKit

enum SyntheticIdentity {
    static let operation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
struct Fixture {
    let id: String
    let phase: String
    var title = "Synthetic Expedition"
    var verified: Int64 = 25_000_000
    var total: Int64 = 100_000_000
    var stale = false
    var type: DynamicTypeSize = .large
    static let longTitle = "Synthetic Expedition: A Very Long Game Title — 日本語 and Unicode for Layout Checks"
    static let all: [Fixture] = [
        .init(id: "preparing", phase: "resolving", verified: 0, total: 0),
        .init(id: "downloading", phase: "downloading"),
        .init(id: "checking", phase: "verifying"),
        .init(id: "finishing", phase: "finalizing"),
        .init(id: "paused", phase: "paused"),
        .init(id: "foreground", phase: "waitingForeground"),
        .init(id: "stale", phase: "downloading", stale: true),
        .init(id: "failed", phase: "failed"),
        .init(id: "completed", phase: "completed", verified: 100_000_000),
        .init(id: "long-title", phase: "downloading", title: longTitle),
        .init(id: "large-text", phase: "waitingForeground", title: longTitle, type: .accessibility3),
    ]
    var data: SteamDownloadViewData {
        .init(attributes: .init(operationId: SyntheticIdentity.operation.uuidString, gameName: title),
              state: .init(phase: phase, verifiedBytes: verified, totalBytes: total,
                           lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)), isStale: stale)
    }
}

// Only the fields consumed by the unchanged production Activity coordinator.
enum FixtureStatus: String { case downloading, completed, failed, cancelled }
struct SteamDownloadJob {
    var id = SyntheticIdentity.operation
    var name = "Synthetic Expedition"
    var completedBytes: Int64 = 25_000_000
    var totalBytes: Int64 = 100_000_000
    var phase = "downloading"
    var status = FixtureStatus.downloading
}
enum LiveContainerIntegration { static func isHosted() -> Bool { false } }

@MainActor final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()
    @Published var fixture = Fixture.all[1]
    @Published var ready = false
    @Published var error: String?
    private var started = false
    private var job = SteamDownloadJob()
    private var events: [[String: Any]] = []
    static var output: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("activity-captures", isDirectory: true)
    }
    func restore() async { /* Production intent bridges to synthetic state only. */ }
    func prepare() async {
        guard !started else { return }
        started = true
        do {
            try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
            try ComponentRenderer.save(to: Self.output)
            ready = true
            await select(Fixture.all[1])
        } catch { self.error = String(describing: error) }
    }
    func select(_ next: Fixture) async {
        await SteamDownloadActivity.shared.recoverAfterRelaunch()
        fixture = next
        job = .init(name: next.title, completedBytes: next.verified, totalBytes: next.total, phase: next.phase)
        SteamDownloadActivity.shared.begin(job)
        SteamDownloadActivity.shared.update(job, phase: next.phase, force: true)
        if let terminal = FixtureStatus(rawValue: next.phase), terminal != .downloading {
            job.status = terminal
            SteamDownloadActivity.shared.end(job)
        }
        record("select")
    }
    func cancel(_ id: UUID) {
        guard id == job.id else { return }
        job.status = .cancelled
        job.phase = "cancelled"
        fixture = .init(id: "cancelled", phase: "cancelled")
        SteamDownloadActivity.shared.end(job)
        record("cancel")
    }
    var status: String {
        let values: [String: Any] = ["enabled": ActivityAuthorizationInfo().areActivitiesEnabled,
            "count": Activity<SteamDownloadActivityAttributes>.activities.count,
            "states": Activity<SteamDownloadActivityAttributes>.activities.map { String(describing: $0.activityState) },
            "fixture": fixture.id, "phase": fixture.phase]
        return String(data: try! JSONSerialization.data(withJSONObject: values, options: .sortedKeys), encoding: .utf8)!
    }
    private func record(_ action: String) {
        events.append(["action": action, "fixture": fixture.id, "phase": fixture.phase,
                       "title": job.name, "verifiedBytes": job.completedBytes, "totalBytes": job.totalBytes,
                       "authorizationEnabled": ActivityAuthorizationInfo().areActivitiesEnabled,
                       "evidence": "synthetic app controls using production Activity coordinator"])
        do {
            try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
                .write(to: Self.output.appendingPathComponent("app-events.json"), options: .atomic)
        } catch { self.error = String(describing: error) }
    }
}

@main struct FixtureDemoApp: App {
    var body: some Scene { WindowGroup { FixtureDemoView() } }
}
struct FixtureDemoView: View {
    @StateObject private var model = SteamLibraryModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Iridium Activity demo").font(.title2.bold())
                Text("Synthetic data • no Steam connection").font(.subheadline).foregroundStyle(.secondary)
                Text("Production presentation").font(.caption.bold())
                SteamDownloadCard(context: model.fixture.data)
                    .environment(\.dynamicTypeSize, model.fixture.type)
                    .background(Color(white: 0.07)).clipShape(RoundedRectangle(cornerRadius: 16))
                Text(model.fixture.id).accessibilityIdentifier("selectedFixture")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(ActivityAuthorizationInfo().areActivitiesEnabled ? "Live Activities enabled" : "Live Activities unavailable")
                        .font(.caption).accessibilityIdentifier("activityStatus").accessibilityValue(model.status)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                    ForEach(Fixture.all, id: \.id) { item in
                        Button(item.id) { Task { await model.select(item) } }
                            .buttonStyle(.bordered).accessibilityIdentifier("state.\(item.id)")
                    }
                }
                Button("Cancel synthetic job") { model.cancel(SyntheticIdentity.operation) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("cancelFixture")
                Text("The real Activity coordinator starts, updates and ends these fixtures. System stale status appears after 30 seconds. Large text here affects the app/component preview; system text size is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.ready { Text("Components ready").accessibilityIdentifier("componentsReady") }
                if let error = model.error { Text(error).accessibilityIdentifier("captureError") }
            }.padding()
        }.preferredColorScheme(.dark).task { await model.prepare() }
    }
}

@MainActor enum ComponentRenderer {
    static func save(to root: URL) throws {
        let directory = root.appendingPathComponent("components", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        var cards: [(Fixture, UIImage, UIImage)] = []
        for fixture in Fixture.all {
            let surfaces: [(String, AnyView, CGFloat)] = [
                ("card", AnyView(SteamDownloadCard(context: fixture.data)), 320),
                ("expanded-bottom", AnyView(SteamDownloadCard(context: fixture.data, expandedIsland: true)), 300),
                ("compact-leading", AnyView(SteamDownloadSymbol(context: fixture.data).frame(width: 24, height: 24)), 24),
                ("compact-trailing", AnyView(SteamDownloadRing(context: fixture.data).frame(width: 24, height: 24)), 24),
                ("minimal", AnyView(SteamDownloadRing(context: fixture.data).frame(width: 24, height: 24)), 24),
            ]
            var pair: [UIImage] = []
            for (name, view, width) in surfaces {
                let content = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .background(Color(white: 0.07)).environment(\.colorScheme, .dark)
                    .environment(\.dynamicTypeSize, fixture.type).environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                let image = try capture(content, width: width)
                if pair.count < 2 { pair.append(image) }
                var variants = [(name, image)]
                if name == "card" {
                    variants.append(("card-clipped-160", try capture(content.frame(height: 160, alignment: .topLeading)
                        .clipped().overlay(Rectangle().strokeBorder(Color(red: 1, green: 0, blue: 1))), width: width)))
                }
                for (variant, pngImage) in variants {
                    let filename = "\(fixture.id)-\(variant).png"
                    guard let png = pngImage.pngData(), let pixels = pngImage.cgImage else {
                        throw NSError(domain: "SyntheticCapture", code: 1)
                    }
                    try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                    records.append(["file": filename, "fixture": fixture.id, "phase": fixture.phase,
                        "surface": variant, "evidence": "production SwiftUI component render; not a system container",
                        "isStale": fixture.stale, "dynamicType": String(describing: fixture.type),
                        "widthPixels": pixels.width, "heightPixels": pixels.height,
                        "naturalHeightPoints": image.size.height, "exceeds160PointProbe": image.size.height > 160])
                }
            }
            cards.append((fixture, pair[0], pair[1]))
        }
        let preview = root.appendingPathComponent("preview", isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        for start in stride(from: 0, to: cards.count, by: 4) {
            let rows = Array(cards[start..<min(start + 4, cards.count)])
            let height = 90 + rows.reduce(0) { $0 + max($1.1.size.height, $1.2.size.height) + 55 }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: 680, height: height), format: format).image { context in
                UIColor.black.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 680, height: height))
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.white]
                ("SYNTHETIC COMPONENTS • not system containers\nCard at 320pt | expanded Island bottom at 300pt" as NSString)
                    .draw(at: CGPoint(x: 12, y: 12), withAttributes: attributes)
                var y: CGFloat = 90
                for (fixture, card, expanded) in rows {
                    ("\(fixture.id) • \(fixture.phase)" as NSString).draw(at: CGPoint(x: 12, y: y), withAttributes: attributes)
                    card.draw(in: CGRect(x: 12, y: y + 25, width: 320, height: card.size.height))
                    expanded.draw(in: CGRect(x: 355, y: y + 25, width: 300, height: expanded.size.height))
                    y += max(card.size.height, expanded.size.height) + 55
                }
            }
            try sheet.pngData()!.write(to: preview.appendingPathComponent("components-\(start / 4 + 1).png"), options: .atomic)
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
    private static func capture<Content: View>(_ view: Content, width: CGFloat) throws -> UIImage {
        let renderer = ImageRenderer(content: view); renderer.scale = 2; renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = renderer.uiImage, image.size.width > 0, image.size.height > 0 else {
            throw NSError(domain: "SyntheticCapture", code: 2)
        }
        return image
    }
}
