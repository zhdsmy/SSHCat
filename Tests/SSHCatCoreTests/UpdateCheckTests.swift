import Foundation
import Testing
@testable import SSHCatCore

@Suite struct UpdateCheckTests {
    @Test func comparesNumericVersionsAndIgnoresAppBuild() throws {
        let release = Data(#"{"tag_name":"v0.10.0"}"#.utf8)
        #expect(try UpdateCheck.newer(than: "0.9.9 (14)", releaseJSON: release) == "v0.10.0")
    }

    @Test func equalOrOlderReleaseIsNotAnUpdate() throws {
        let same = Data(#"{"tag_name":"v0.1.0"}"#.utf8)
        let older = Data(#"{"tag_name":"v0.0.9"}"#.utf8)
        #expect(try UpdateCheck.newer(than: "0.1.0 (1)", releaseJSON: same) == nil)
        #expect(try UpdateCheck.newer(than: "0.1.0 (1)", releaseJSON: older) == nil)
    }

    @Test func rejectsInvalidAndDevelopmentVersions() throws {
        for current in ["开发版", "0.1", "0.1.0-dev", "0.1.0 (beta)", "01.1.0"] {
            let release = Data(#"{"tag_name":"v0.2.0"}"#.utf8)
            #expect(throws: URLError.self) {
                try UpdateCheck.newer(than: current, releaseJSON: release)
            }
        }

        for tag in ["development", "v0.2", "v0.2.0-beta", "v01.2.0"] {
            let release = try JSONSerialization.data(withJSONObject: ["tag_name": tag])
            #expect(throws: URLError.self) {
                try UpdateCheck.newer(than: "0.1.0 (1)", releaseJSON: release)
            }
        }
    }
}
