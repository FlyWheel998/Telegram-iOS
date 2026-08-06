import Foundation

// Pure-Foundation core for "remove this text from posts".
// Deliberately free of UIKit / TelegramCore so it can be compiled and tested off-device.
// Integration layer maps SGEntity <-> TelegramCore.MessageTextEntity.

/// A rule always belongs to exactly one chat. There is deliberately no global scope:
/// a short phrase removed everywhere would silently eat text in unrelated chats,
/// and the user would have no reliable way to notice.
public struct SGRemovalRule: Codable, Equatable {
    public var id: String
    public var text: String
    public var peerId: Int64
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, text: String, peerId: Int64, isEnabled: Bool = true) {
        self.id = id
        self.text = text
        self.peerId = peerId
        self.isEnabled = isEnabled
    }

    public func applies(toPeerId: Int64) -> Bool {
        return self.isEnabled && self.peerId == toPeerId
    }
}

/// Stand-in for TelegramCore.MessageTextEntity. Offsets are UTF-16 units, matching Telegram's model.
public struct SGEntity: Equatable {
    public var range: NSRange
    public var kind: String

    public init(range: NSRange, kind: String) {
        self.range = range
        self.kind = kind
    }
}

// MARK: - Normalisation

/// Folds text for tolerant matching while retaining a map back to original UTF-16 offsets.
///
/// Three transforms are applied, chosen to match how channel footers actually vary between posts:
/// case, combining marks (Hebrew niqqud / Arabic tashkeel — note that Foundation's
/// `.diacriticInsensitive` does NOT strip these, only Latin ones), and whitespace runs.
/// Because every transform can change UTF-16 length, each emitted unit records the original
/// span it came from, so a match in normalised space can be projected back exactly.
public enum SGTextNormalizer {

    public struct Normalized {
        public let text: String
        /// Per emitted UTF-16 unit: the (start, end) UTF-16 span in the original string.
        let origin: [(start: Int, end: Int)]

        /// Projects a range in normalised space back to original UTF-16 coordinates.
        public func originalRange(for normalized: NSRange) -> NSRange? {
            guard normalized.length > 0,
                  normalized.location >= 0,
                  normalized.location + normalized.length <= self.origin.count
            else { return nil }
            let start = self.origin[normalized.location].start
            let end = self.origin[normalized.location + normalized.length - 1].end
            guard end > start else { return nil }
            return NSRange(location: start, length: end - start)
        }
    }

    public static func isNonspacingMark(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.properties.generalCategory == .nonspacingMark
    }

    public static func normalize(_ input: String) -> Normalized {
        var out = String.UnicodeScalarView()
        var origin: [(start: Int, end: Int)] = []
        var lastEmittedWasSpace = false
        var cursor = 0

        for scalar in input.unicodeScalars {
            let width = UTF16.width(scalar)
            let spanStart = cursor
            let spanEnd = cursor + width
            cursor = spanEnd

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if lastEmittedWasSpace { continue }
                out.append(" ")
                origin.append((spanStart, spanEnd))
                lastEmittedWasSpace = true
                continue
            }

            // Decompose so precomposed forms expose their combining marks, then drop the marks.
            for decomposed in String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars {
                if isNonspacingMark(decomposed) { continue }
                for lowered in String(decomposed).lowercased().unicodeScalars {
                    out.append(lowered)
                    // One origin entry per UTF-16 unit, not per scalar: astral scalars (emoji)
                    // occupy a surrogate pair, and a short map desynchronises every later offset.
                    for _ in 0 ..< UTF16.width(lowered) {
                        origin.append((spanStart, spanEnd))
                    }
                }
            }
            lastEmittedWasSpace = false
        }

        return Normalized(text: String(out), origin: origin)
    }
}

// MARK: - Removal

public enum SGTextRemover {

    /// Ranges (original UTF-16 coordinates) matched by any applicable rule, merged and sorted.
    public static func removalRanges(in text: String, rules: [SGRemovalRule], peerId: Int64) -> [NSRange] {
        let applicable = rules.filter { $0.applies(toPeerId: peerId) }
        guard !applicable.isEmpty, !text.isEmpty else { return [] }

        let haystack = SGTextNormalizer.normalize(text)
        guard !haystack.text.isEmpty else { return [] }
        let haystackNS = haystack.text as NSString

        var found: [NSRange] = []
        for rule in applicable {
            let needle = SGTextNormalizer.normalize(rule.text).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }

            var searchFrom = 0
            while searchFrom < haystackNS.length {
                let scope = NSRange(location: searchFrom, length: haystackNS.length - searchFrom)
                let hit = haystackNS.range(of: needle, options: [], range: scope)
                guard hit.location != NSNotFound else { break }
                if let mapped = haystack.originalRange(for: hit) {
                    found.append(mapped)
                }
                searchFrom = hit.location + max(hit.length, 1)
            }
        }
        return merge(found)
    }

    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            let lastEnd = last.location + last.length
            if r.location <= lastEnd {
                let newEnd = max(lastEnd, r.location + r.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Applies removals to text and shifts/clips entities to stay aligned.
    /// Returns the original untouched if nothing matched, so callers can cheaply detect a no-op.
    public static func strip(
        text: String,
        entities: [SGEntity],
        rules: [SGRemovalRule],
        peerId: Int64
    ) -> (text: String, entities: [SGEntity]) {
        let ranges = removalRanges(in: text, rules: rules, peerId: peerId)
        guard !ranges.isEmpty else { return (text, entities) }

        var result = text as NSString
        var working = entities

        // Back-to-front so earlier offsets stay valid as we cut.
        for range in ranges.reversed() {
            result = result.replacingCharacters(in: range, with: "") as NSString
            working = working.compactMap { shift($0, removing: range) }
        }

        // Removing a footer leaves dangling blank lines; removing a leading banner
        // leaves the post starting with a space. Trim both, shifting entities each time.
        if let cut = trailingWhitespaceRange(result) {
            result = result.replacingCharacters(in: cut, with: "") as NSString
            working = working.compactMap { shift($0, removing: cut) }
        }
        if let cut = leadingWhitespaceRange(result) {
            result = result.replacingCharacters(in: cut, with: "") as NSString
            working = working.compactMap { shift($0, removing: cut) }
        }

        return (result as String, working)
    }

    static func shift(_ entity: SGEntity, removing cut: NSRange) -> SGEntity? {
        let eStart = entity.range.location
        let eEnd = eStart + entity.range.length
        let cStart = cut.location
        let cEnd = cStart + cut.length

        if eEnd <= cStart { return entity }                     // entirely before the cut
        if eStart >= cEnd {                                     // entirely after
            var moved = entity
            moved.range = NSRange(location: eStart - cut.length, length: entity.range.length)
            return moved
        }
        // Overlapping: keep whatever survives on each side, dropping the excised middle.
        let survivingBefore = max(0, cStart - eStart)
        let survivingAfter = max(0, eEnd - cEnd)
        let newLength = survivingBefore + survivingAfter
        guard newLength > 0 else { return nil }
        var clipped = entity
        clipped.range = NSRange(location: min(eStart, cStart), length: newLength)
        return clipped
    }

    static func trailingWhitespaceRange(_ s: NSString) -> NSRange? {
        var end = s.length
        while end > 0 {
            let unit = s.character(at: end - 1)
            guard let scalar = Unicode.Scalar(UInt32(unit)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            end -= 1
        }
        guard end < s.length else { return nil }
        return NSRange(location: end, length: s.length - end)
    }

    static func leadingWhitespaceRange(_ s: NSString) -> NSRange? {
        var start = 0
        while start < s.length {
            let unit = s.character(at: start)
            guard let scalar = Unicode.Scalar(UInt32(unit)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            start += 1
        }
        guard start > 0 else { return nil }
        return NSRange(location: 0, length: start)
    }
}
