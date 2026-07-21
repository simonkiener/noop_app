import XCTest
import Foundation
@testable import StrandImport

/// Pins the offline file-import of a user's OWN Fitbit data export onto NOOP's daily
/// metrics + sleep sessions. Tiny inline fixtures per brand (no real account data). HONEST DATA:
/// only fields the export carries are written.
final class WearableExportImporterTests: XCTestCase {

    private func bytes(_ s: String) -> Data { s.data(using: .utf8)! }

    // MARK: - Fitbit

    func testFitbitSleepRestingHrSteps() {
        let sleep = """
        [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
            "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20,
            "efficiency": 94,
            "levels": { "summary": {
              "deep": { "minutes": 80 }, "light": { "minutes": 220 },
              "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
        let rhr = """
        [ { "dateTime": "2026-06-01T00:00:00.000", "value": { "date": "2026-06-01", "value": 51.5, "error": 5.0 } } ]
        """
        let steps = """
        [ { "dateTime": "2026-06-01 08:00:00", "value": "1200" },
          { "dateTime": "2026-06-01 09:00:00", "value": "800" } ]
        """
        let files = [
            "sleep-2026-06-01.json": bytes(sleep),
            "resting_heart_rate-2026-06-01.json": bytes(rhr),
            "steps-2026-06-01.json": bytes(steps),
        ]
        XCTAssertEqual(WearableExportImporter.detectBrand(files), .fitbit)
        let r = WearableExportImporter.parse(brand: .fitbit, files: files)

        XCTAssertEqual(r.summary.sourceKind, .fitbitImport)
        XCTAssertEqual(r.sleeps.count, 1)
        let s = r.sleeps[0]
        XCTAssertEqual(s.totalSleepMin!, 400, accuracy: 1e-6)
        XCTAssertEqual(s.deepMin!, 80, accuracy: 1e-6)
        XCTAssertEqual(s.remMin!, 100, accuracy: 1e-6)
        XCTAssertEqual(s.efficiencyPct!, 94, accuracy: 1e-6)

        XCTAssertEqual(r.days.count, 1)
        let d = r.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.restingHr, 51)                          // nested value.value, rounded
        XCTAssertEqual(d.steps, 2000)                            // intraday steps summed
        XCTAssertEqual(d.totalSleepMin!, 400, accuracy: 1e-6)
    }

    // MARK: - Safety / honesty

    func testJunkAndZeroValuesAreRejectedSafely() {
        // Not a wearable export at all → no brand.
        XCTAssertNil(WearableExportImporter.detectBrand(["random.json": bytes("{\"foo\":1}")]))
    }
}
