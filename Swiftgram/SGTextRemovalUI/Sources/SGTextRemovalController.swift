// MARK: Swiftgram
import SGItemListUI
import SGStrings
import SGTextRemoval

import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private enum SGTextRemovalSection: Int32, SGItemListSection {
    case info
    case rules
}

private enum SGTextRemovalAction: Hashable {
    case delete(ruleId: String)
}

private typealias SGTextRemovalEntry = SGItemListUIEntry<
    SGTextRemovalSection,
    AnyHashable,      // no toggles
    AnyHashable,      // no sliders
    AnyHashable,      // no one-from-many selectors
    AnyHashable,      // no disclosure links
    SGTextRemovalAction
>

/// A rule paired with the chat it belongs to, resolved for display.
private struct SGResolvedRule {
    let rule: SGRemovalRule
    let peerTitle: String
}

private func sgTextRemovalEntries(
    presentationData: PresentationData,
    resolved: [SGResolvedRule]
) -> [SGTextRemovalEntry] {
    let lang = presentationData.strings.baseLanguageCode
    var entries: [SGTextRemovalEntry] = []
    var id = 0

    if resolved.isEmpty {
        // Without this the screen is a blank page with no explanation of how to populate it.
        entries.append(.notice(id: id, section: .info, text: i18n("TextRemoval.Empty", lang)))
        return entries
    }

    entries.append(.header(id: id, section: .rules, text: i18n("TextRemoval.SectionHeader", lang), badge: nil))
    id += 1

    for item in resolved {
        // Chat name is folded into the row rather than becoming a section header: section
        // identity is an Int32 rawValue, so per-peer sections would mean synthesising stable
        // numeric ids for arbitrary peers. Not worth the fragility for a management screen.
        let displayText = "\(item.peerTitle) — \u{201C}\(item.rule.text)\u{201D}"
        entries.append(.action(
            id: id,
            section: .rules,
            actionType: .delete(ruleId: item.rule.id),
            text: displayText,
            kind: .destructive
        ))
        id += 1
    }

    return entries
}

public func sgTextRemovalController(context: AccountContext) -> ViewController {
    // Rules live in UserDefaults, not Postbox, so there is no database signal to observe.
    // This promise is pulsed after every mutation to re-render the list.
    let reloadPromise = ValuePromise<Bool>(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGTextRemovalAction>(
        context: context,
        action: { action in
            switch action {
            case let .delete(ruleId):
                SGTextRemovalService.shared.remove(id: ruleId)
                reloadPromise.set(true)
            }
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        reloadPromise.get()
    )
    |> mapToSignal { presentationData, _ -> Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> in
        let rules = SGTextRemovalService.shared.allRules()
        let peerIds = Array(Set(rules.map { PeerId($0.peerId) }))

        // One batched lookup rather than one per rule; a chat commonly has several rules.
        return context.engine.data.get(
            EngineDataMap(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) })
        )
        |> map { peerMap -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let resolved: [SGResolvedRule] = rules.map { rule in
                let peerId = PeerId(rule.peerId)
                let title = peerMap[peerId].flatMap { $0 }?.compactDisplayTitle
                    ?? presentationData.strings.Conversation_DeletedChat
                return SGResolvedRule(rule: rule, peerTitle: title)
            }
            // Group rules from the same chat together, then keep a stable order within a chat.
            .sorted { lhs, rhs in
                if lhs.peerTitle != rhs.peerTitle { return lhs.peerTitle < rhs.peerTitle }
                return lhs.rule.text < rhs.rule.text
            }

            let entries = sgTextRemovalEntries(presentationData: presentationData, resolved: resolved)

            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(i18n("TextRemoval.SectionHeader", presentationData.strings.baseLanguageCode)),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks
            )
            return (controllerState, (listState, arguments))
        }
    }

    return ItemListController(context: context, state: signal)
}
