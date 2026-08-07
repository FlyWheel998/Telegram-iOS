import Foundation

var passed = 0, failed = 0
func expect(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("PASS  \(label)") }
    else { failed += 1; print("FAIL  \(label)\(detail.isEmpty ? "" : "  -> \(detail)")") }
}
func expectEq(_ label: String, _ a: String, _ b: String) {
    expect(label, a == b, "got \"\(a)\" expected \"\(b)\"")
}

let CHANNEL: Int64 = 1001
let OTHER: Int64 = 2002

// ---------------------------------------------------------------- basic
do {
    let r = [SGRemovalRule(text: " -- sponsored", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "Big news today -- sponsored", entities: [], rules: r, peerId: CHANNEL)
    expectEq("basic strip", out.text, "Big news today")
}

// ---------------------------------------------------------------- real Hebrew footer (from desktop HANDOFF)
do {
    let footer = "למבזק המיוחד לחצו כאן"
    let post = "כותרת הידיעה החשובה\n\n\(footer)"
    let r = [SGRemovalRule(text: footer, peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: post, entities: [], rules: r, peerId: CHANNEL)
    expectEq("hebrew footer removed", out.text, "כותרת הידיעה החשובה")
}

// ---------------------------------------------------------------- diacritic tolerance (the probe bug)
do {
    // Rule captured from UNPOINTED text; post arrives POINTED.
    let r = [SGRemovalRule(text: "מיוחד", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "דיווח מִיוּחָד מהשטח", entities: [], rules: r, peerId: CHANNEL)
    expect("unpointed rule matches pointed post", !out.text.contains("מִיוּחָד"), "got \"\(out.text)\"")
}
do {
    // ...and the reverse: rule captured from POINTED text, post is unpointed.
    let r = [SGRemovalRule(text: "מִיוּחָד", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "דיווח מיוחד מהשטח", entities: [], rules: r, peerId: CHANNEL)
    expect("pointed rule matches unpointed post", !out.text.contains("מיוחד"), "got \"\(out.text)\"")
}
do {
    let r = [SGRemovalRule(text: "محمد", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "قال مُحَمَّد اليوم", entities: [], rules: r, peerId: CHANNEL)
    expect("arabic tashkeel tolerance", !out.text.contains("مُحَمَّد"), "got \"\(out.text)\"")
}

// ---------------------------------------------------------------- whitespace tolerance
do {
    let r = [SGRemovalRule(text: "click here now", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "Story.\n\nclick   here\nnow", entities: [], rules: r, peerId: CHANNEL)
    expectEq("whitespace-variant footer removed", out.text, "Story.")
}

// ---------------------------------------------------------------- case tolerance
do {
    let r = [SGRemovalRule(text: "SPONSORED", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "News sponsored", entities: [], rules: r, peerId: CHANNEL)
    expectEq("case-insensitive", out.text, "News")
}

// ---------------------------------------------------------------- scoping
do {
    let r = [SGRemovalRule(text: "junk", peerId: CHANNEL)]
    let same = SGTextRemover.strip(text: "keep junk", entities: [], rules: r, peerId: CHANNEL)
    let other = SGTextRemover.strip(text: "keep junk", entities: [], rules: r, peerId: OTHER)
    expectEq("scoped rule fires in its channel", same.text, "keep")
    expectEq("scoped rule silent elsewhere", other.text, "keep junk")
}
do {
    let r = [SGRemovalRule(text: "junk", peerId: OTHER)]
    let other = SGTextRemover.strip(text: "keep junk", entities: [], rules: r, peerId: OTHER)
    expectEq("rule fires in its own channel only", other.text, "keep")
}
do {
    let r = [SGRemovalRule(id: "x", text: "junk", peerId: CHANNEL, isEnabled: false)]
    let out = SGTextRemover.strip(text: "keep junk", entities: [], rules: r, peerId: CHANNEL)
    expectEq("disabled rule is inert", out.text, "keep junk")
}

// ---------------------------------------------------------------- no-op identity
do {
    let r = [SGRemovalRule(text: "absent", peerId: CHANNEL)]
    let src = "nothing to do here"
    let out = SGTextRemover.strip(text: src, entities: [], rules: r, peerId: CHANNEL)
    expect("no match returns input unchanged", out.text == src)
}

// ---------------------------------------------------------------- entity handling
do {
    // "AAA BBB CCC" — link on CCC (loc 8 len 3). Remove "AAA " (loc 0 len 4).
    let ent = [SGEntity(range: NSRange(location: 8, length: 3), kind: "url")]
    let r = [SGRemovalRule(text: "AAA", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "AAA BBB CCC", entities: ent, rules: r, peerId: CHANNEL)
    let e = out.entities.first
    let slice = e.map { (out.text as NSString).substring(with: $0.range) } ?? "<none>"
    expectEq("entity after cut still points at CCC", slice, "CCC")
}
do {
    // Link on AAA (loc 0 len 3); remove trailing "CCC" — entity must not move.
    let ent = [SGEntity(range: NSRange(location: 0, length: 3), kind: "url")]
    let r = [SGRemovalRule(text: "CCC", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "AAA BBB CCC", entities: ent, rules: r, peerId: CHANNEL)
    let slice = out.entities.first.map { (out.text as NSString).substring(with: $0.range) } ?? "<none>"
    expectEq("entity before cut unmoved", slice, "AAA")
}
do {
    // Entity sits entirely inside the removed span -> must be dropped, not left dangling.
    let ent = [SGEntity(range: NSRange(location: 4, length: 3), kind: "bold")]
    let r = [SGRemovalRule(text: "BBB", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "AAA BBB CCC", entities: ent, rules: r, peerId: CHANNEL)
    expect("entity inside cut dropped", out.entities.isEmpty, "left \(out.entities.count)")
}
do {
    // Entity straddles the cut boundary -> clipped, and must stay in bounds.
    let ent = [SGEntity(range: NSRange(location: 0, length: 7), kind: "bold")]  // "AAA BBB"
    let r = [SGRemovalRule(text: "BBB", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "AAA BBB CCC", entities: ent, rules: r, peerId: CHANNEL)
    let ns = out.text as NSString
    let e = out.entities.first
    let inBounds = e.map { $0.range.location + $0.range.length <= ns.length } ?? false
    expect("straddling entity clipped in-bounds", inBounds,
           "text=\"\(out.text)\" len=\(ns.length) ent=\(String(describing: e?.range))")
}

// ---------------------------------------------------------------- emoji offsets
do {
    // Emoji is 2 UTF-16 units; entity offsets must survive a cut placed after it.
    let src = "hi 👋 promo tail"
    let ent = [SGEntity(range: NSRange(location: 0, length: 2), kind: "bold")]  // "hi"
    let r = [SGRemovalRule(text: "promo tail", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: src, entities: ent, rules: r, peerId: CHANNEL)
    let slice = out.entities.first.map { (out.text as NSString).substring(with: $0.range) } ?? "<none>"
    expectEq("entity intact across emoji", slice, "hi")
    expectEq("emoji preserved", out.text, "hi 👋")
}

// ---------------------------------------------------------------- multiple + overlapping
do {
    let r = [SGRemovalRule(text: "one", peerId: CHANNEL), SGRemovalRule(text: "three", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "one two three", entities: [], rules: r, peerId: CHANNEL)
    expectEq("two rules both applied", out.text, "two")
}
do {
    let merged = SGTextRemover.merge([NSRange(location: 0, length: 5), NSRange(location: 3, length: 5)])
    expect("overlapping ranges merged", merged.count == 1 && merged[0].length == 8,
           "\(merged.map { "\($0.location)+\($0.length)" })")
}

// ---------------------------------------------------------------- repeated occurrences
do {
    let r = [SGRemovalRule(text: "ad", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "ad news ad sport ad", entities: [], rules: r, peerId: CHANNEL)
    expect("all occurrences removed", !out.text.contains("ad"), "got \"\(out.text)\"")
}

// ================================================================ store

func newStore() -> SGRemovalRuleStore { SGRemovalRuleStore(storage: SGInMemoryRuleStorage()) }

do {
    let s = newStore()
    guard case .success(let rule) = s.add(text: "sponsored", peerId: CHANNEL) else {
        expect("store: add succeeds", false); exit(1)
    }
    expect("store: add succeeds", true)
    expect("store: rule readable for its peer", s.rules(forPeerId: CHANNEL).contains(rule))
    expect("store: rule absent for other peer", s.rules(forPeerId: OTHER).isEmpty)
}

do {
    let s = newStore()
    _ = s.add(text: "sponsored", peerId: CHANNEL)
    if case .failure(.duplicate) = s.add(text: "sponsored", peerId: CHANNEL) {
        expect("store: exact duplicate rejected", true)
    } else { expect("store: exact duplicate rejected", false) }
}

do {
    // A rule differing only by case, spacing or vowel points is the same rule to the
    // matcher, so the store must not let lookalikes accumulate.
    let s = newStore()
    _ = s.add(text: "מיוחד", peerId: CHANNEL)
    if case .failure(.duplicate) = s.add(text: "מִיוּחָד", peerId: CHANNEL) {
        expect("store: diacritic variant is a duplicate", true)
    } else { expect("store: diacritic variant is a duplicate", false) }

    let s2 = newStore()
    _ = s2.add(text: "Sponsored Post", peerId: CHANNEL)
    if case .failure(.duplicate) = s2.add(text: "sponsored   post", peerId: CHANNEL) {
        expect("store: case/spacing variant is a duplicate", true)
    } else { expect("store: case/spacing variant is a duplicate", false) }
}

do {
    let s = newStore()
    if case .failure(.empty) = s.add(text: "   \n ", peerId: CHANNEL) {
        expect("store: empty selection rejected", true)
    } else { expect("store: empty selection rejected", false) }

    if case .failure(.tooShort) = s.add(text: "a", peerId: CHANNEL) {
        expect("store: 1-char selection rejected", true)
    } else { expect("store: 1-char selection rejected", false) }
}

do {
    // An imprecise selection drag picks up surrounding whitespace.
    let s = newStore()
    guard case .success(let rule) = s.add(text: "  promo tail \n", peerId: CHANNEL) else {
        expect("store: selection whitespace trimmed", false); exit(1)
    }
    expectEq("store: selection whitespace trimmed", rule.text, "promo tail")
}

do {
    let s = newStore()
    guard case .success(let rule) = s.add(text: "junk", peerId: CHANNEL) else { exit(1) }
    expect("store: remove returns true", s.remove(id: rule.id))
    expect("store: rule gone after remove", s.rules(forPeerId: CHANNEL).isEmpty)
    expect("store: removing unknown id is false", !s.remove(id: "no-such-id"))
}

do {
    let s = newStore()
    guard case .success(let rule) = s.add(text: "junk", peerId: CHANNEL) else { exit(1) }
    expect("store: peer reports rules present", !s.isEmpty(forPeerId: CHANNEL))
    _ = s.setEnabled(false, id: rule.id)
    expect("store: disabled rule makes peer empty", s.isEmpty(forPeerId: CHANNEL))
    expect("store: disabled rule still listed for management", s.rules(forPeerId: CHANNEL).count == 1)
}

do {
    // Rules must survive a relaunch, so the encoded form has to round-trip.
    let backing = SGInMemoryRuleStorage()
    let first = SGRemovalRuleStore(storage: backing)
    _ = first.add(text: "persist me", peerId: CHANNEL)
    _ = first.add(text: "למבזק המיוחד לחצו כאן", peerId: OTHER)

    let reloaded = SGRemovalRuleStore(storage: backing)
    expect("store: survives reload", reloaded.allRules().count == 2, "got \(reloaded.allRules().count)")
    expectEq("store: unicode survives reload",
             reloaded.rules(forPeerId: OTHER).first?.text ?? "<none>",
             "למבזק המיוחד לחצו כאן")
}

do {
    let s = newStore()
    _ = s.add(text: "aaa", peerId: CHANNEL)
    _ = s.add(text: "bbb", peerId: CHANNEL)
    _ = s.add(text: "ccc", peerId: OTHER)
    let groups = s.groupedByPeer()
    let channelCount = groups.first(where: { $0.peerId == CHANNEL })?.rules.count
    expect("store: grouped by peer", groups.count == 2 && channelCount == 2,
           "\(groups.map { "\($0.peerId):\($0.rules.count)" })")
    expect("store: removeAll for peer", s.removeAll(forPeerId: CHANNEL) == 2)
    expect("store: other peer untouched", s.rules(forPeerId: OTHER).count == 1)
}

do {
    // End to end: a rule added from a selection actually cleans the post it came from.
    let s = newStore()
    let post = "כותרת הידיעה החשובה\n\nלמבזק המיוחד לחצו כאן"
    _ = s.add(text: "למבזק המיוחד לחצו כאן", peerId: CHANNEL)
    let out = SGTextRemover.strip(text: post, entities: [],
                                  rules: s.rules(forPeerId: CHANNEL), peerId: CHANNEL)
    expectEq("end-to-end: stored rule cleans the post", out.text, "כותרת הידיעה החשובה")
}

// ================================================================ range API (integration surface)

do {
    // Positional contract: result[i] corresponds to input[i]. TelegramCore entities carry a
    // rich type that must survive, so callers keep their own values and only remap ranges.
    let rules = [SGRemovalRule(text: "BBB", peerId: CHANNEL)]
    let input = [
        NSRange(location: 0, length: 3),   // AAA - before the cut
        NSRange(location: 4, length: 3),   // BBB - inside the cut, must become nil
        NSRange(location: 8, length: 3),   // CCC - after the cut
    ]
    let out = SGTextRemover.strip(text: "AAA BBB CCC", entityRanges: input, rules: rules, peerId: CHANNEL)
    expect("range API: arity preserved", out.mappedRanges.count == input.count)
    expect("range API: index 1 removed", out.mappedRanges[1] == nil)
    let ns = out.text as NSString
    expectEq("range API: index 0 still AAA", out.mappedRanges[0].map { ns.substring(with: $0) } ?? "<nil>", "AAA")
    expectEq("range API: index 2 still CCC", out.mappedRanges[2].map { ns.substring(with: $0) } ?? "<nil>", "CCC")
}

do {
    // No match must be a true no-op so render paths can skip work entirely.
    let rules = [SGRemovalRule(text: "absent", peerId: CHANNEL)]
    let input = [NSRange(location: 0, length: 2)]
    let out = SGTextRemover.strip(text: "hello world", entityRanges: input, rules: rules, peerId: CHANNEL)
    expectEq("range API: no-op keeps text", out.text, "hello world")
    expect("range API: no-op keeps ranges", out.mappedRanges[0] == input[0])
}

do {
    // Every surviving range must stay inside the new string - an out-of-bounds entity
    // would be applied against an NSString at render time.
    let rules = [SGRemovalRule(text: "למבזק המיוחד לחצו כאן", peerId: CHANNEL)]
    let post = "כותרת חשובה כאן\n\nלמבזק המיוחד לחצו כאן"
    let input = [NSRange(location: 0, length: 6), NSRange(location: 7, length: 5)]
    let out = SGTextRemover.strip(text: post, entityRanges: input, rules: rules, peerId: CHANNEL)
    let len = (out.text as NSString).length
    let inBounds = out.mappedRanges.compactMap { $0 }.allSatisfy { $0.location >= 0 && $0.location + $0.length <= len }
    expect("range API: survivors stay in bounds", inBounds,
           "len=\(len) ranges=\(out.mappedRanges.map { $0.map { "\($0.location)+\($0.length)" } ?? "nil" })")
}

do {
    // Empty entity list is the common case and must not crash.
    let rules = [SGRemovalRule(text: "junk", peerId: CHANNEL)]
    let out = SGTextRemover.strip(text: "keep junk", entityRanges: [], rules: rules, peerId: CHANNEL)
    expectEq("range API: empty entities", out.text, "keep")
    expect("range API: empty result", out.mappedRanges.isEmpty)
}

// ================================================================ service

func newService() -> SGTextRemovalService {
    return SGTextRemovalService(store: SGRemovalRuleStore(storage: SGInMemoryRuleStorage()))
}

do {
    let svc = newService()
    expect("service: no rules initially", !svc.hasRules(forPeerId: CHANNEL))
    _ = svc.add(text: "promo tail", peerId: CHANNEL)
    expect("service: hasRules after add", svc.hasRules(forPeerId: CHANNEL))
    expect("service: other peer unaffected", !svc.hasRules(forPeerId: OTHER))
    expectEq("service: strips", svc.strip(text: "Story. promo tail", peerId: CHANNEL), "Story.")
    expectEq("service: leaves other peers alone", svc.strip(text: "Story. promo tail", peerId: OTHER), "Story. promo tail")
}

do {
    // The render fast path: no rules must return the input by identity, not a rebuilt copy.
    let svc = newService()
    let input = [NSRange(location: 0, length: 3)]
    let out = svc.strip(text: "untouched text", entityRanges: input, peerId: CHANNEL)
    expectEq("service: no-rules fast path text", out.text, "untouched text")
    expect("service: no-rules fast path ranges", out.mappedRanges.first! == input[0])
}

do {
    // Adding a rule must notify, so the open chat can repaint immediately.
    let svc = newService()
    var fired = 0
    let token = svc.observeChanges { fired += 1 }
    _ = svc.add(text: "aaa", peerId: CHANNEL)
    expect("service: add notifies", fired == 1, "fired=\(fired)")

    _ = svc.add(text: "aaa", peerId: CHANNEL)  // duplicate -> rejected
    expect("service: rejected add does not notify", fired == 1, "fired=\(fired)")

    let ruleId = svc.rules(forPeerId: CHANNEL).first!.id
    _ = svc.setEnabled(false, id: ruleId)
    expect("service: toggle notifies", fired == 2, "fired=\(fired)")

    _ = svc.remove(id: ruleId)
    expect("service: remove notifies", fired == 3, "fired=\(fired)")

    _ = svc.remove(id: "nonexistent")
    expect("service: no-op remove does not notify", fired == 3, "fired=\(fired)")

    token.cancel()
    _ = svc.add(text: "bbb", peerId: CHANNEL)
    expect("service: cancelled observer stops firing", fired == 3, "fired=\(fired)")
}

do {
    // Observation must not outlive its token, or handlers leak.
    let svc = newService()
    var fired = 0
    do {
        let token = svc.observeChanges { fired += 1 }
        _ = token  // released at end of scope
    }
    _ = svc.add(text: "ccc", peerId: CHANNEL)
    expect("service: released observation auto-cancels", fired == 0, "fired=\(fired)")
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
