import Foundation
import XCTest

final class TestSupportTests: XCTestCase {
    /// Named suites left an empty plist in ~/Library/Preferences per test, about 14,000 in total.
    func testTempDefaultsStayInsideTheTempRoot() throws {
        let (defaults, suite, root) = try makeTempDefaults("TempDefaultsCleanup")
        defaults.set(true, forKey: "written")
        defaults.synchronize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("defaults.plist").path))

        removeTempDefaults(defaults, suite: suite, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
