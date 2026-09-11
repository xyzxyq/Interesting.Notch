import Foundation
@main struct CompactLyricsChecks {
    static func main() {
        assert(CompactLyrics.split("歌颂这种平凡") == ["歌颂", "这种", "平凡"])
        assert(CompactLyrics.split("也曾像朋友一样和我诉说") == ["也曾像", "朋友", "一样", "和我", "诉说"])
        let lines = CompactLyrics.parseLRC("[offset:-100]\n[00:01.5][00:03.500]歌颂这种平凡\n[00:05.50]\n[bad]ignored")
        assert(lines.count == 3)
        assert(abs(lines[0].time - 1.4) < 0.000001)
        assert(abs(lines[1].time - 3.4) < 0.000001)
        assert(abs(lines[2].time - 5.4) < 0.000001 && lines[2].text.isEmpty)
        let segments = CompactLyrics.timeline([.init(time: 10, text: "歌颂这种平凡"), .init(time: 20, text: "")], duration: 30)
        assert(segments.count == 3)
        assert(CompactLyrics.segment(at: 9, in: segments) == nil)
        assert(CompactLyrics.segment(at: 10, in: segments)?.text == "歌颂")
        assert(CompactLyrics.segment(at: 11, in: segments)?.text == "这种")
        assert(CompactLyrics.segment(at: 12, in: segments)?.text == "平凡")
        assert(CompactLyrics.segment(at: 13, in: segments) == nil)
        assert(CompactLyrics.segment(at: 10, in: segments)?.text == "歌颂") // backward seek
        assert(abs(CompactLyrics.nextBoundary(after: 10, in: segments)! - 10.8) < 0.000001)
        for input in ["你好，世界！", "abcdefg", "👨‍👩‍👧‍👦你好", "e\u{301}1234"] {
            let result = CompactLyrics.split(input)
            assert(result.allSatisfy { (1...3).contains($0.count) })
            let expected = input.filter { !$0.isWhitespace && !$0.isPunctuation }
            assert(result.joined() == String(expected))
        }
        assert(CompactLyrics.timeline([.init(time: 2, text: "你好")], duration: 3).last?.end == 3)
        assert(CompactLyrics.parseLRC("[00:01]你\n[00:01]好") == [LyricLine(time: 1, text: "你好")])
        assert(CompactLyrics.parseLRC("[offset:-2000]\n[00:01]你").first?.time == 0)
        assert(CompactLyrics.parseLRC("[00:99]bad\n[xx:01]bad").isEmpty)
        assert(CompactLyrics.timeline([], duration: 10).isEmpty)
        assert(CompactLyrics.split("， ！").isEmpty)
        assert(CompactLyrics.nextBoundary(after: 30, in: segments) == nil)
        print("CompactLyrics checks passed")
    }
}
