import Foundation

enum PublicChatChannelPresentationMode: Equatable {
    case inlineReplacement
    case navigationDestination
}

enum PublicChatListPresentationMode: Equatable {
    case splitDetail
    case navigationDestination
}

enum PublicChatNavigationPolicy {
    static func listPresentationMode(usesSplitLayout: Bool) -> PublicChatListPresentationMode {
        usesSplitLayout ? .splitDetail : .navigationDestination
    }

    static func channelPresentationMode(isMacCatalyst: Bool) -> PublicChatChannelPresentationMode {
        isMacCatalyst ? .inlineReplacement : .navigationDestination
    }

    static var currentChannelPresentationMode: PublicChatChannelPresentationMode {
        channelPresentationMode(isMacCatalyst: isCurrentPlatformMacCatalyst)
    }

    private static var isCurrentPlatformMacCatalyst: Bool {
#if targetEnvironment(macCatalyst)
        return true
#else
        return false
#endif
    }
}
