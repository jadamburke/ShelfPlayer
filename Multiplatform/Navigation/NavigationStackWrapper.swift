//
//  NavigationSTackWrapper.swift
//  Multiplatform
//
//  Created by Rasmus Krämer on 11.01.25.
//

import SwiftUI
import ShelfPlayback

struct NavigationStackWrapper<Content: View>: View {
    let tab: TabValue
    
    @ViewBuilder var content: () -> Content
    
    @State private var context: NavigationContext
    
    init(tab: TabValue, content: @escaping () -> Content) {
        self.tab = tab
        self.content = content
        
        context = .init(tab: tab)
    }
    
    var body: some View {
        NavigationStack(path: $context.path) {
            content()
                .navigationDestination(for: NavigationDestination.self) { destination in
                    switch destination {
                        case .item(let item, let zoomID):
                            ItemView(item: item, zoomID: zoomID)
                        case .itemID(let itemID):
                            ItemLoadView(itemID)
                            
                        case .itemName(let name, let type):
                            ItemIDLoadView(name: name, type: type)
                            
                        case .podcastEpisodes(let viewModel):
                            PodcastEpisodesView()
                                .environment(viewModel)
                        case .tabValue(let tabValue):
                            tabValue.content
                            
                        case .audiobookRow(let title, let audiobooks):
                            RowGridView(title: title, audiobooks: audiobooks)
                        case .libraryGenres(let genre):
                            AudiobookLibraryPanel(filterGenre: genre)
                        case .libraryTags(let tag):
                            AudiobookLibraryPanel(filterTag: tag)
                            
                    }
                }
                .onReceive(RFNotification[._navigate].publisher()) {
                    let libraryID: String?
                    
                    if case .audiobookHome(let library) = tab {
                        libraryID = library.id
                    } else if case .podcastHome(let library) = tab {
                        libraryID = library.id
                    } else {
                        libraryID = nil
                    }
                    
                    guard let libraryID, $0.libraryID == libraryID else {
                        return
                    }
                    
                    context.path.append(.itemID($0))
                }
        }
        .environment(\.library, tab.library)
        .environment(\.navigationContext, context)
        .onReceive(RFNotification[.collectionDeleted].publisher()) { collectionID in
            context.path.removeAll {
                $0.itemID == collectionID
            }
        }
    }
}

@MainActor @Observable
final class NavigationContext {
    let tab: TabValue
    
    init(tab: TabValue) {
        self.tab = tab
    }
    
    var path = [NavigationDestination]()
}
extension EnvironmentValues {
    @Entry var navigationContext: NavigationContext? = nil
}

enum NavigationDestination: Hashable {
    case item(Item, UUID?)
    case itemID(ItemIdentifier)
    
    case itemName(String, ItemIdentifier.ItemType)
    
    case podcastEpisodes(PodcastViewModel)
    case tabValue(TabValue)
    
    case audiobookRow(String, [Audiobook])
    
    case libraryGenres(String)
    case libraryTags(String)
    
    static func item(_ item: Item) -> Self {
        .item(item, nil)
    }
    
    var itemID: ItemIdentifier? {
        switch self {
            case .item(let item, _):
                item.id
            case .itemID(let itemID):
                itemID
            case .podcastEpisodes(let viewModel):
                viewModel.podcast.id
            default:
                nil
        }
    }
    var label: String {
        switch self {
            case .item(let item, _):
                item.name
            case .itemID(let itemID):
                itemID.type.label
            case .itemName(let name, _):
                name
            case .podcastEpisodes(let viewModel):
                "\(String(localized: "item.related.podcast.episodes")): \(viewModel.podcast.name)"
            case .tabValue(let tab):
                tab.label
            case .audiobookRow(let title, _):
                title
            case .libraryGenres(let genre):
                genre
            case .libraryTags(let tags):
                tags
        }
    }
}
