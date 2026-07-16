import Foundation

enum BroadcastChannelPresentationMode: Equatable {
    case inlineReplacement
    case navigationDestination
}

enum BroadcastListPresentationMode: Equatable {
    case splitDetail
    case navigationDestination
}

enum BroadcastNavigationPolicy {
    static func listPresentationMode(usesSplitLayout: Bool) -> BroadcastListPresentationMode {
        usesSplitLayout ? .splitDetail : .navigationDestination
    }

    static func channelPresentationMode(isMacCatalyst: Bool) -> BroadcastChannelPresentationMode {
        isMacCatalyst ? .inlineReplacement : .navigationDestination
    }

    static var currentChannelPresentationMode: BroadcastChannelPresentationMode {
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
