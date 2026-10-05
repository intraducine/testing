// SPDX-License-Identifier: AGPL-3.0-only
import ActivityKit
import SwiftUI
import UIKit

// Original procedural landscape, drawn locally. No fetched or commercial asset.
@MainActor enum SyntheticArtwork {
    enum Failure: Error, Equatable { case notPrepared, gradientUnavailable, thumbnailUnavailable, jpegUnavailable, jpegTooLarge }
    private(set) static var image: UIImage?
    private(set) static var jpeg: Data?

    static func prepare() throws {
        let colors = [UIColor(red: 0.04, green: 0.2, blue: 0.3, alpha: 1).cgColor,
                      UIColor(red: 0.85, green: 0.45, blue: 0.2, alpha: 1).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else {
            throw Failure.gradientUnavailable
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80), format: format).image { renderer in
            let context = renderer.cgContext
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
        let encoded = try thumbnailJPEG(from: landscape)
        image = landscape
        jpeg = encoded
    }

    static func thumbnailJPEG(from image: UIImage,
        encode: (UIImage) -> Data? = { $0.jpegData(compressionQuality: 0.25) }) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        guard let pixels = thumbnail.cgImage, pixels.width == 80, pixels.height == 40 else {
            throw Failure.thumbnailUnavailable
        }
        guard let encoded = encode(thumbnail), !encoded.isEmpty else { throw Failure.jpegUnavailable }
        guard encoded.count <= 1_450 else { throw Failure.jpegTooLarge }
        return encoded
    }
}

private struct FixturePayload: Encodable {
    let attributes: SteamDownloadActivityAttributes
    let state: SteamDownloadActivityAttributes.ContentState
}

@MainActor enum FixtureActivityGate {
    struct Observation {
        let state: UIApplication.State
        let enabled: Bool
        let hosted: Bool
        var guardExit: String? {
            if hosted { return "hosted" }
            if state != .active { return "applicationState != active" }
            if !enabled { return "activities disabled" }
            return nil
        }
        var record: [String: Any] {
            let name: String
            switch state {
            case .active: name = "active"
            case .inactive: name = "inactive"
            case .background: name = "background"
            @unknown default: name = "unknown"
            }
            return ["applicationState": name, "authorizationEnabled": enabled, "hosted": hosted,
                    "guardExit": guardExit ?? "none"]
        }
    }
    static func observe() -> Observation {
        .init(state: UIApplication.shared.applicationState,
              enabled: ActivityAuthorizationInfo().areActivitiesEnabled, hosted: LiveContainerIntegration.isHosted())
    }
    static func waitForForeground(attempts: Int = 300,
        observe: () -> Observation = { FixtureActivityGate.observe() },
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }) async throws -> Observation {
        var current = observe()
        for _ in 0..<attempts {
            if current.state == .active || current.hosted || !current.enabled { return current }
            try await pause()
            current = observe()
        }
        return current
    }
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
            report["foregroundAtPayloadStart"] = FixtureActivityGate.observe().record
            let active = FixtureActivityGate.Observation(state: .active, enabled: true, hosted: false)
            let inactive = FixtureActivityGate.Observation(state: .inactive, enabled: true, hosted: false)
            let background = FixtureActivityGate.Observation(state: .background, enabled: true, hosted: false)
            try require(active.guardExit == nil, "Active fixture guard was rejected")
            try require(inactive.guardExit == "applicationState != active", "Inactive guard exit was hidden")
            try require(background.guardExit == "applicationState != active", "Background guard exit was hidden")
            try require(FixtureActivityGate.Observation(state: .active, enabled: false, hosted: false).guardExit == "activities disabled", "Disabled guard exit was hidden")
            try require(FixtureActivityGate.Observation(state: .active, enabled: true, hosted: true).guardExit == "hosted", "Hosted guard exit was hidden")
            var polls = 0
            let becameActive = try await FixtureActivityGate.waitForForeground(attempts: 2,
                observe: { return [inactive, background, active][polls] }, pause: { polls += 1 })
            try require(becameActive.guardExit == nil && polls == 2, "Foreground transition was not awaited")
            polls = 0
            let timedOut = try await FixtureActivityGate.waitForForeground(attempts: 2,
                observe: { inactive }, pause: { polls += 1 })
            try require(timedOut.guardExit != nil && polls == 2, "Foreground timeout was counted as eligibility")
            polls = 0
            _ = try await FixtureActivityGate.waitForForeground(observe: { active }, pause: { polls += 1 })
            try require(polls == 0, "Active fixture unnecessarily waited")
            do {
                _ = try await FixtureActivityGate.waitForForeground(observe: { inactive }, pause: { throw CancellationError() })
                try require(false, "Foreground cancellation was discarded")
            } catch is CancellationError { checks += 1 }
            report["foregroundGuardChecksPassed"] = true
            guard let artwork = SyntheticArtwork.image, let jpeg = SyntheticArtwork.jpeg else { throw SyntheticArtwork.Failure.notPrepared }
            try require(artwork.cgImage?.width == 160 && artwork.cgImage?.height == 80, "Synthetic landscape dimensions changed")
            let decoded = UIImage(data: jpeg)?.cgImage
            try require(decoded?.width == 80 && decoded?.height == 40, "Synthetic JPEG thumbnail dimensions changed")
            try require(jpeg.count <= 1_450, "Synthetic JPEG exceeds production thumbnail budget")
            report["jpegBytes"] = jpeg.count
            let invalidEncodings: [(Data?, SyntheticArtwork.Failure)] = [
                (nil, .jpegUnavailable), (Data(), .jpegUnavailable),
                (Data(repeating: 0, count: 1_451), .jpegTooLarge)]
            for (invalid, expected) in invalidEncodings {
                do {
                    _ = try SyntheticArtwork.thumbnailJPEG(from: artwork, encode: { _ in invalid })
                    try require(false, "Invalid synthetic JPEG encoder result was accepted")
                } catch let error as SyntheticArtwork.Failure {
                    try require(error == expected, "Unexpected synthetic JPEG encoder failure")
                }
            }
            report["artworkEncodingFailureChecksPassed"] = true
            let attributes = SteamDownloadActivityAttributes(operationId: SyntheticIdentity.operation.uuidString,
                gameName: String(repeating: "👨‍👩‍👧‍👦", count: 80))
            report["unicodeTitleCharacters"] = attributes.gameName.count
            report["unicodeTitleUTF8Bytes"] = attributes.gameName.utf8.count
            let rates: [Double?] = [nil, 12_000_000, -1, Double.nan, Double.infinity, Double(Int64.max)]
            let images: [Data?] = [nil, jpeg, Data(repeating: 255, count: 1_450),
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
            report["foregroundBeforeWait"] = FixtureActivityGate.observe().record
            _ = try await FixtureActivityGate.waitForForeground()
            let beforeBegin = FixtureActivityGate.observe()
            report["productionBeginGuards"] = beforeBegin.record
            report["coordinatorResetBeforeBegin"] = true
            if let reason = beforeBegin.guardExit {
                report["productionBeginOutcome"] = "guard exit; begin not invoked"
                try require(false, "Production begin guard exit: \(reason)")
            }
            SteamDownloadActivity.shared.begin(job)
            report["productionBeginOutcome"] = "invoked after observed public guards passed"
            SteamDownloadActivity.shared.update(job, force: true, receivedBytesPerSecond: 12_000_000)
            try await Task.sleep(for: .milliseconds(300))
            guard let activity = Activity<SteamDownloadActivityAttributes>.activities.first(where: { $0.attributes.operationId == job.id.uuidString }) else {
                report["productionBeginOutcome"] = "no matching Activity after begin; production catch does not expose its error"
                report["separateDiagnosticRequest"] = await diagnosticRequest(job)
                try require(false, "No matching Activity after production begin; see guard observations and separateDiagnosticRequest"); return
            }
            let before = activity.content
            try require(before.state.phase == "downloading" && before.state.receivedBytesPerSecond == 12_000_000,
                "Initial rate/progress update was not accepted")
            SteamDownloadActivity.shared.cacheArtwork(Image(uiImage: artwork), for: job.appId)
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

    // A separate synthetic API attempt only after production registration fails.
    // Its success never satisfies the production acceptance assertions above.
    private static func diagnosticRequest(_ job: SteamDownloadJob) async -> [String: Any] {
        let observation = FixtureActivityGate.observe()
        var result: [String: Any] = ["guards": observation.record, "scope": "separate diagnostic API attempt; not the production error"]
        if let reason = observation.guardExit {
            result["outcome"] = "guard exit: \(reason)"; return result
        }
        let attributes = SteamDownloadActivityAttributes(operationId: job.id.uuidString, gameName: String(job.name.prefix(80)))
        let state = SteamDownloadActivityAttributes.ContentState(phase: "resolving", verifiedBytes: max(0, job.completedBytes),
            totalBytes: max(0, job.totalBytes), lastUpdated: Date(), receivedBytesPerSecond: nil, artworkJPEG: nil)
        let content = ActivityContent(state: state.bounded(for: attributes), staleDate: Date().addingTimeInterval(30))
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            result["outcome"] = "accepted; ended immediately; production check still failed"
            await activity.end(nil, dismissalPolicy: .immediate)
        } catch {
            let actual = error as NSError
            result["outcome"] = "threw"
            result["errorDomain"] = actual.domain; result["errorCode"] = actual.code
            result["errorDescription"] = actual.localizedDescription
            if let underlying = actual.userInfo[NSUnderlyingErrorKey] as? NSError {
                result["underlyingErrorDomain"] = underlying.domain
                result["underlyingErrorCode"] = underlying.code
                result["underlyingErrorDescription"] = underlying.localizedDescription
            }
        }
        return result
    }
}
