// Run from repo root: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift BoringNotchXPCHelper/BoringNotchXPCHelper.swift boringNotch/models/PlaybackState.swift boringNotch/models/CompactLyrics.swift scripts/DisplayMetadataChecks.swift -o /tmp/interesting-display-metadata-checks && /tmp/interesting-display-metadata-checks
import Foundation
import CoreGraphics

@main struct DisplayMetadataChecks {
    static func main() throws {
        let select = BoringNotchXPCHelper.selectBrightnessTarget
        assert(select([2, 1], 2, { $0 == 1 }, { $0 == 1 ? 0.4 : nil })?.id == 1)
        assert(select([2, 1], 2, { $0 == 1 }, { _ in 0.5 })?.id == 1)
        assert(select([2, 3], 2, { _ in false }, { $0 == 3 ? 0.6 : nil })?.id == 3)
        assert(select([2], 2, { _ in false }, { _ in nil }) == nil)
        assert(select([1], 1, { _ in true }, { _ in .nan }) == nil)
        assert(select([], 0, { _ in false }, { _ in 0 }) == nil)
        func update(_ json: String) throws -> NowPlayingUpdate {
            try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(json.utf8))
        }
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state = state.applying(try update(#"{"payload":{"bundleIdentifier":"com.apple.Music","title":"A","uniqueIdentifier":1777357772}}"#))
        assert(state.catalogID == 1777357772)
        state = state.applying(try update(#"{"diff":true,"payload":{"elapsedTime":10}}"#))
        assert(state.catalogID == 1777357772)
        let opaque = state.applying(try update(#"{"diff":true,"payload":{"uniqueIdentifier":"opaque-id"}}"#))
        assert(opaque.catalogID == nil, "An explicit non-catalog ID clears the preceding catalog ID")
        state = state.applying(try update(#"{"diff":true,"payload":{"title":"B"}}"#))
        assert(state.catalogID == nil)
        state = state.applying(try update(#"{"diff":true,"payload":{"uniqueIdentifier":"opaque-id"}}"#))
        assert(state.catalogID == nil)
        assert(LocalizedMusicMetadata.lookupURL(id: 1, languages: ["zh-Hans-CN"])!.absoluteString.contains("country=cn"))
        assert(LocalizedMusicMetadata.lookupURL(id: 1, languages: ["zh-Hant-TW"])!.absoluteString.contains("country=tw"))
        assert(LocalizedMusicMetadata.lookupURL(id: 1, languages: ["en-US"]) == nil)
        let data = Data(#"{"results":[{"trackId":1,"trackName":"我好想你","artistName":"苏打绿","collectionName":"秋:故事"}]}"#.utf8)
        let matched = try LocalizedMusicMetadata.decode(data, id: 1)
        assert(matched?.artistName == "苏打绿")
        let unmatched = try LocalizedMusicMetadata.decode(data, id: 2)
        assert(unmatched == nil)
        assert(CompactLyrics.displayText("蘇打綠", languages: ["zh-Hans-CN"]) == "苏打绿")
        assert(CompactLyrics.displayText("苏打绿", languages: ["zh-Hant-TW"]) == "蘇打綠")
        print("Display selection and metadata checks passed")
        if CommandLine.arguments.contains("--hardware") {
            let helper = BoringNotchXPCHelper()
            helper.currentScreenBrightness { value in
                print("Hardware brightness:", value as Any)
                if let value {
                    let original = value.floatValue
                    let target = original > 0.9 ? original - 0.02 : original + 0.02
                    var wrote = false
                    var readback: Float?
                    helper.setScreenBrightness(target) { wrote = $0 }
                    Thread.sleep(forTimeInterval: 0.2)
                    helper.currentScreenBrightness { readback = $0?.floatValue }
                    var restored = false
                    helper.setScreenBrightness(original) { restored = $0 }
                    print("Hardware target/readback:", target, readback as Any, "restored:", restored)
                    // Restore before assertions: assertion failures abort without running defer.
                    assert(restored && wrote && readback != nil && abs(readback! - target) < 0.01)
                }
            }
        }
    }
}
