// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic host only. No Steam engine, accounts, network or game files.
import ActivityKit
import SwiftUI
import UIKit

enum SyntheticIdentity {
    static let operation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
@MainActor struct Fixture {
    let id: String
    let phase: String
    var title = "Synthetic Expedition"
    var verified: Int64 = 25_000_000
    var total: Int64 = 100_000_000
    var stale = false
    var type: DynamicTypeSize = .large
    var rate: Double? = 12_000_000
    var hasArtwork = true
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
        .init(id: "no-art", phase: "downloading", hasArtwork: false),
        .init(id: "no-rate", phase: "downloading", rate: nil),
    ]
    var data: SteamDownloadViewData {
        let attributes = SteamDownloadActivityAttributes(operationId: SyntheticIdentity.operation.uuidString,
            gameName: String(title.prefix(80)))
        let state = SteamDownloadActivityAttributes.ContentState(phase: phase, verifiedBytes: verified, totalBytes: total,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), receivedBytesPerSecond: rate,
            artworkJPEG: hasArtwork ? SyntheticArtwork.jpeg : nil).bounded(for: attributes)
        return .init(attributes: attributes, state: state, isStale: stale)
    }
}

// Only the fields consumed by the reviewed production Activity coordinator.
enum FixtureStatus: String { case downloading, completed, failed, cancelled }
struct SteamDownloadJob {
    var id = SyntheticIdentity.operation
    var appId: UInt32 = 424_242
    var name = "Synthetic Expedition"
    var completedBytes: Int64 = 25_000_000
    var totalBytes: Int64 = 100_000_000
    var phase = "downloading"
    var status = FixtureStatus.downloading
}
enum LiveContainerIntegration { static func isHosted() -> Bool { false } }

@MainActor enum CaptureProgress {
    private static let started = ProcessInfo.processInfo.systemUptime
    static func record(_ stage: String, to output: URL, error: String? = nil) throws {
        var state: [String: Any] = ["stage": stage,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]
        if let error { state["error"] = error }
        try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
            .write(to: output.appendingPathComponent("startup-progress.json"), options: .atomic)
    }
}

@MainActor final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()
    @Published var fixture = Fixture.all[1]
    @Published var componentsReady = false
    @Published var activityReady = false
    @Published var error: String?
    private var started = false
    private var artworkPrepared = false
    private var job = SteamDownloadJob()
    private var events: [[String: Any]] = []
    static var output: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("activity-captures", isDirectory: true)
    }
    func restore() async { /* Production intent bridges to synthetic state only. */ }
    func prepareArtwork() {
        guard !artworkPrepared else { return }
        do {
            try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
            try CaptureProgress.record("artwork-started", to: Self.output)
            try SyntheticArtwork.prepare()
            try CaptureProgress.record("artwork-prepared", to: Self.output)
            artworkPrepared = true
        } catch {
            let cause = String(describing: error)
            self.error = cause
            do { try CaptureProgress.record("artwork-failed", to: Self.output, error: cause) }
            catch { self.error = cause + "; startup marker failed: " + String(describing: error) }
        }
    }
    func prepare() async {
        guard artworkPrepared, !started else { return }
        started = true
        do {
            try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
            try CaptureProgress.record("prepare-started", to: Self.output)
            try ComponentRenderer.save(to: Self.output)
            componentsReady = true
            try CaptureProgress.record("payload-checks", to: Self.output)
            try await PayloadChecks.run(to: Self.output)
            try CaptureProgress.record("payload-checks-passed", to: Self.output)
            guard let artwork = SyntheticArtwork.image else { throw SyntheticArtwork.Failure.notPrepared }
            SteamDownloadActivity.shared.cacheArtwork(Image(uiImage: artwork), for: 424_242)
            await select(Fixture.all[1])
            try await Task.sleep(for: .milliseconds(300))
            guard Activity<SteamDownloadActivityAttributes>.activities.contains(where: { $0.attributes.operationId == job.id.uuidString }) else {
                throw NSError(domain: "SyntheticCapture", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: error ?? "Initial fixture Activity registration is missing"])
            }
            try CaptureProgress.record("ready", to: Self.output)
            activityReady = true
        } catch { self.error = String(describing: error) }
    }
    func select(_ next: Fixture) async {
        await SteamDownloadActivity.shared.recoverAfterRelaunch()
        do { _ = try await FixtureActivityGate.waitForForeground() }
        catch { self.error = String(describing: error); return }
        let beforeBegin = FixtureActivityGate.observe()
        events.append(["action": "before-begin", "fixture": next.id, "guards": beforeBegin.record,
                       "coordinatorResetBeforeBegin": true])
        if let reason = beforeBegin.guardExit {
            self.error = "Production begin guard exit: \(reason)"
            record("select-guard-exit"); return
        }
        if next.hasArtwork, let artwork = SyntheticArtwork.image {
            SteamDownloadActivity.shared.cacheArtwork(Image(uiImage: artwork), for: 424_242)
        }
        fixture = next
        job = .init(appId: next.hasArtwork ? 424_242 : 424_243, name: next.title, completedBytes: next.verified, totalBytes: next.total, phase: next.phase)
        SteamDownloadActivity.shared.begin(job)
        SteamDownloadActivity.shared.update(job, phase: next.phase, force: true, receivedBytesPerSecond: next.rate)
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
        let activities = Activity<SteamDownloadActivityAttributes>.activities
        let selected = activities.first { $0.attributes.operationId == job.id.uuidString }
        let values: [String: Any] = ["enabled": ActivityAuthorizationInfo().areActivitiesEnabled,
            "requestAccepted": selected != nil, "hasArtwork": selected?.content.state.artworkJPEG != nil,
            "encodedPayloadBytes": selected.flatMap { try? PayloadChecks.bytes($0.attributes, $0.content.state) } ?? 0,
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

@main @MainActor struct FixtureDemoApp: App {
    init() { SteamLibraryModel.shared.prepareArtwork() }
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
                            .buttonStyle(.bordered).disabled(!model.activityReady).accessibilityIdentifier("state.\(item.id)")
                    }
                }
                Button("Cancel synthetic job") { model.cancel(SyntheticIdentity.operation) }
                    .buttonStyle(.borderedProminent).disabled(!model.activityReady).accessibilityIdentifier("cancelFixture")
                Text("The real Activity coordinator starts, updates and ends these fixtures. System stale status appears after 30 seconds. Large text here affects the app/component preview; system text size is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.componentsReady { Text("Components ready").accessibilityIdentifier("componentsReady") }
                if model.activityReady { Text("Activity checks ready").accessibilityIdentifier("activityReady") }
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
            try CaptureProgress.record("rendering-\(fixture.id)", to: root)
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
                        "encodedPayloadBytes": try PayloadChecks.bytes(fixture.data.attributes, fixture.data.state),
                        "artworkBytes": fixture.data.state.artworkJPEG?.count ?? 0,
                        "visibleReceivedRate": fixture.data.presentation.receivedRateSummary ?? "unavailable",
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
        try CaptureProgress.record("components-saved", to: root)
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
