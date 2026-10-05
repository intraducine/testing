// SPDX-License-Identifier: AGPL-3.0-only
import ActivityKit
import SwiftUI
import UIKit

// Original procedural landscape, drawn locally. No fetched or commercial asset.
@MainActor enum SyntheticArtwork {
    static let image: UIImage = {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80), format: format).image { renderer in
            let context = renderer.cgContext
            let colors = [UIColor(red: 0.04, green: 0.2, blue: 0.3, alpha: 1).cgColor,
                          UIColor(red: 0.85, green: 0.45, blue: 0.2, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 80), options: [])
            UIColor(red: 1, green: 0.8, blue: 0.45, alpha: 1).setFill()
            context.fillEllipse(in: CGRect(x: 110, y: 15, width: 17, height: 17))
            for (points, color) in [
                ([CGPoint(x: 0, y: 57), CGPoint(x: 35, y: 24), CGPoint(x: 60, y: 51),
                  CGPoint(x: 93, y: 35), CGPoint(x: 130, y: 58), CGPoint(x: 160, y: 39)],
                 UIColor(red: 0.11, green: 0.25, blue: 0.29, alpha: 1)),
                ([CGPoint(x: 0, y: 72), CGPoint(x: 45, y: 52), CGPoint(x: 86, y: 65),
                  CGPoint(x: 123, y: 45), CGPoint(x: 160, y: 64)],
                 UIColor(red: 0.03, green: 0.1, blue: 0.13, alpha: 1))] {
                context.beginPath(); context.move(to: CGPoint(x: 0, y: 80))
                for point in points { context.addLine(to: point) }
                context.addLine(to: CGPoint(x: 160, y: 80)); context.closePath()
                context.setFillColor(color.cgColor); context.fillPath()
            }
        }
    }()
    static let jpeg: Data = {
        let renderer = ImageRenderer(content: Image(uiImage: image).resizable().scaledToFill().frame(width: 80, height: 40).clipped())
        renderer.scale = 1
        return renderer.uiImage!.jpegData(compressionQuality: 0.25)!
    }()
}

private struct FixturePayload: Encodable {
    let attributes: SteamDownloadActivityAttributes
    let state: SteamDownloadActivityAttributes.ContentState
}

@MainActor enum PayloadChecks {
    static func bytes(_ attributes: SteamDownloadActivityAttributes,
                      _ state: SteamDownloadActivityAttributes.ContentState) throws -> Int {
        try JSONEncoder().encode(FixturePayload(attributes: attributes, state: state)).count
    }

    static func run(to output: URL) async throws {
        var report: [String: Any] = ["status": "running", "artworkSource": "original locally drawn synthetic landscape"]
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "PayloadChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func save() throws {
            report["checks"] = checks
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("payload-checks.json"), options: .atomic)
        }
        do {
            try require(SyntheticArtwork.jpeg.count <= 1_450, "Synthetic JPEG exceeds production thumbnail budget")
            report["jpegBytes"] = SyntheticArtwork.jpeg.count
            let attributes = SteamDownloadActivityAttributes(operationId: SyntheticIdentity.operation.uuidString,
                gameName: String(repeating: "👨‍👩‍👧‍👦", count: 80))
            report["unicodeTitleCharacters"] = attributes.gameName.count
            report["unicodeTitleUTF8Bytes"] = attributes.gameName.utf8.count
            let rates: [Double?] = [nil, 12_000_000, -1, Double.nan, Double.infinity, Double(Int64.max)]
            let images: [Data?] = [nil, SyntheticArtwork.jpeg, Data(repeating: 255, count: 1_450),
                                  Data(repeating: 255, count: 1_451), Data(repeating: 0, count: 8_192)]
            var maximum = 0
            for phase in ["resolving", "downloading", "verifying", "finalizing", "waitingForeground", "paused", "failed", "completed", "cancelled"] {
                for rate in rates {
                    for image in images {
                        let state = SteamDownloadActivityAttributes.ContentState(phase: phase,
                            verifiedBytes: Int64.max, totalBytes: Int64.max,
                            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
                            receivedBytesPerSecond: rate, artworkJPEG: image).bounded(for: attributes)
                        let count = try bytes(attributes, state); maximum = max(maximum, count)
                        try require(count <= 3_072, "80-family-emoji title/state exceeds encoded payload budget")
                        if let image, image.count > 1_450 { try require(state.artworkJPEG == nil, "Oversized image was retained") }
                        if let rate, !rate.isFinite || rate < 1 || rate >= Double(Int64.max) {
                            try require(state.receivedBytesPerSecond == nil, "Invalid rate was retained")
                        }
                    }
                }
            }
            report["maximumEncodedPayloadBytes"] = maximum
            for (phase, stale) in [("downloading", true), ("paused", false), ("waitingForeground", false), ("completed", false)] {
                let presentation = SteamDownloadPresentation(phase: phase, verifiedBytes: 25, totalBytes: 100,
                    isStale: stale, receivedBytesPerSecond: 12_000_000)
                try require(presentation.receivedRateSummary == nil, "Inactive/stale rate remains visible")
            }
            report["authorizationEnabled"] = ActivityAuthorizationInfo().areActivitiesEnabled
            try require(ActivityAuthorizationInfo().areActivitiesEnabled, "ActivityKit is unavailable on this simulator")
            await SteamDownloadActivity.shared.recoverAfterRelaunch()
            var job = SteamDownloadJob(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                appId: 424_244, name: "Synthetic late-artwork probe")
            SteamDownloadActivity.shared.begin(job)
            SteamDownloadActivity.shared.update(job, force: true, receivedBytesPerSecond: 12_000_000)
            try await Task.sleep(for: .milliseconds(300))
            guard let activity = Activity<SteamDownloadActivityAttributes>.activities.first(where: { $0.attributes.operationId == job.id.uuidString }) else {
                try require(false, "Production Activity.request was not accepted"); return
            }
            let before = activity.content
            try require(before.state.phase == "downloading" && before.state.receivedBytesPerSecond == 12_000_000,
                "Initial rate/progress update was not accepted")
            SteamDownloadActivity.shared.cacheArtwork(Image(uiImage: SyntheticArtwork.image), for: job.appId)
            try await Task.sleep(for: .milliseconds(300))
            let after = activity.content
            try require(after.state == before.state && after.staleDate == before.staleDate,
                "Late artwork refreshed an old rate/progress timestamp")
            try await Task.sleep(for: .milliseconds(5_200))
            job.completedBytes = 37_000_000
            SteamDownloadActivity.shared.update(job, receivedBytesPerSecond: 9_000_000)
            try await Task.sleep(for: .milliseconds(300))
            let current = activity.content.state
            try require(current.verifiedBytes == 37_000_000 && current.receivedBytesPerSecond == 9_000_000,
                "Normal sampled update did not replace the old progress/rate")
            try require(current.artworkJPEG != nil, "ActivityKit did not accept the thumbnail update")
            let count = try bytes(activity.attributes, current)
            try require(count <= 3_072, "Accepted artwork state exceeds payload budget")
            report["activityRequestAccepted"] = true
            report["artworkUpdateAccepted"] = true
            report["acceptedEncodedPayloadBytes"] = count
            report["lateArtworkDidNotRefreshOldSample"] = true
            job.status = .cancelled
            SteamDownloadActivity.shared.end(job)
            await SteamDownloadActivity.shared.recoverAfterRelaunch()
            report["status"] = "passed"
            try save()
        } catch {
            report["status"] = "failed"; report["error"] = String(describing: error)
            try save()
            await SteamDownloadActivity.shared.recoverAfterRelaunch()
            throw error
        }
    }
}
