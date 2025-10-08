//
//  DownloadSubsystem.swift
//  ShelfPlayerKit
//
//  Created by Rasmus Krämer on 25.12.24.
//

import Foundation
import SwiftData
import OSLog
import Network
import RFNotifications

#if canImport(UIKit)
import UIKit
#endif

typealias PersistedAudiobook = SchemaV2.PersistedAudiobook
typealias PersistedEpisode = SchemaV2.PersistedEpisode
typealias PersistedPodcast = SchemaV2.PersistedPodcast

typealias PersistedAsset = SchemaV2.PersistedAsset
typealias PersistedChapter = SchemaV2.PersistedChapter

private let ASSET_ATTEMPT_LIMIT = 3
private let ACTIVE_TASK_LIMIT = 4

extension PersistenceManager {
    @ModelActor
    public final actor DownloadSubsystem {
        let logger = Logger(subsystem: "io.rfk.shelfPlayerKit", category: "Download")
        
        var blocked = [ItemIdentifier: Int]()
        var busy = Set<ItemIdentifier>()
       
        var updateTask: Task<Void, Never>?
        
        private lazy var urlSession: URLSession = {
            let config = URLSessionConfiguration.background(withIdentifier: "io.rfk.shelfPlayerKit.download")
            
            // config.isDiscretionary = !Defaults[.allowCellularDownloads]
            
            config.sessionSendsLaunchEvents = true
            config.waitsForConnectivity = true
            
            config.timeoutIntervalForRequest = 120
            
            config.httpCookieStorage = ShelfPlayerKit.httpCookieStorage
            config.httpShouldSetCookies = true
            config.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
            
            if ShelfPlayerKit.enableCentralized {
                config.sharedContainerIdentifier = ShelfPlayerKit.groupContainer
            }
            
            return URLSession(configuration: config, delegate: URLSessionDelegate(), delegateQueue: nil)
        }()
        
        func persistedAudiobook(for itemID: ItemIdentifier) -> PersistedAudiobook? {
            var descriptor = FetchDescriptor<PersistedAudiobook>(predicate: #Predicate {
                $0._id == itemID.description
            })
            descriptor.fetchLimit = 1
            
            return (try? modelContext.fetch(descriptor))?.first
        }
        func persistedEpisode(for itemID: ItemIdentifier) -> PersistedEpisode? {
            var descriptor = FetchDescriptor<PersistedEpisode>(predicate: #Predicate {
                $0._id == itemID.description
            })
            descriptor.fetchLimit = 1
            
            return (try? modelContext.fetch(descriptor))?.first
        }
        func persistedPodcast(for itemID: ItemIdentifier) -> PersistedPodcast? {
            var descriptor = FetchDescriptor<PersistedPodcast>(predicate: #Predicate {
                $0._id == itemID.description
            })
            descriptor.fetchLimit = 1
            
            return (try? modelContext.fetch(descriptor))?.first
        }
        
        func remove(connectionID: ItemIdentifier.ConnectionID) async {
            do {
                try modelContext.delete(model: PersistedAudiobook.self, where: #Predicate { $0._id.contains(connectionID) })
                
                for podcast in try podcasts() {
                    do {
                        try await remove(podcast.id)
                    } catch {
                        logger.error("Failure removing downloads related to connection (4) \(connectionID, privacy: .public): \(error)")
                    }
                }
            } catch {
                logger.error("Failed to remove downloads related to connection (1) \(connectionID, privacy: .public): \(error)")
            }
            
            do {
                try modelContext.delete(model: PersistedAsset.self, where: #Predicate { $0._itemID.contains(connectionID) })
                try modelContext.delete(model: PersistedChapter.self, where: #Predicate { $0._itemID.contains(connectionID) })
            } catch {
                logger.error("Failed to remove downloads related to connection (2) \(connectionID, privacy: .public): \(error)")
            }
            
            do {
                let path = ShelfPlayerKit.downloadDirectoryURL.appending(path: connectionID.replacing("/", with: "_"))
                try FileManager.default.removeItem(at: path)
            } catch {
                logger.error("Failed to remove download directory for connection (3) \(connectionID, privacy: .public): \(error)")
            }
            
            RFNotification[.downloadStatusChanged].dispatch(payload: nil)
        }
    }
}

private extension PersistenceManager.DownloadSubsystem {
    var nextAsset: (UUID, ItemIdentifier, PersistedAsset.FileType)? {
        var descriptor = FetchDescriptor<PersistedAsset>(predicate: #Predicate { $0.isDownloaded == false && $0.downloadTaskID == nil })
        descriptor.fetchLimit = 1
        
        guard let asset = (try? modelContext.fetch(descriptor))?.first else {
            return nil
        }
        
        return (asset.id, asset.itemID, asset.fileType)
    }
    
    func downloadTask(for identifier: Int) async -> URLSessionDownloadTask? {
        await urlSession.tasks.2.first(where: { $0.taskIdentifier == identifier })
    }
    
    func asset(for identifier: UUID) -> PersistedAsset? {
        var descriptor = FetchDescriptor<PersistedAsset>(predicate: #Predicate { $0.id == identifier })
        descriptor.fetchLimit = 1
        
        return (try? modelContext.fetch(descriptor))?.first
    }
    func asset(taskIdentifier: Int) -> PersistedAsset? {
        var descriptor = FetchDescriptor<PersistedAsset>(predicate: #Predicate { $0.downloadTaskID == taskIdentifier })
        descriptor.fetchLimit = 1
        
        return (try? modelContext.fetch(descriptor))?.first
    }
    
    func assets(for itemID: ItemIdentifier) throws -> [PersistedAsset] {
        try modelContext.fetch(FetchDescriptor<PersistedAsset>(predicate: #Predicate { $0._itemID == itemID.description }))
    }
    func removeAssets(_ assets: [PersistedAsset]) async throws {
        let tasks = await urlSession.allTasks
        
        for asset in assets {
            if asset.isDownloaded {
                try? FileManager.default.removeItem(at: asset.path)
            } else if let taskID = asset.downloadTaskID {
                tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
            }
            
            modelContext.delete(asset)
        }
    }
    
    func fetchDownloadStatus(of itemID: ItemIdentifier) -> DownloadStatus {
        do {
            let assets = try assets(for: itemID)
            
            if assets.isEmpty {
                return .none
            }
            
            let completed = assets.reduce(true) { $0 && $1.isDownloaded }
            let status: DownloadStatus = completed ? .completed : .downloading
            
            return status
        } catch {
            return .none
        }
    }
    
    func handleCompletion(taskIdentifier: Int) async {
        guard let asset = asset(taskIdentifier: taskIdentifier) else {
            assetDownloadFailed(taskIdentifier: taskIdentifier)
            return
        }
        
        let current = PersistenceManager.DownloadSubsystem.temporaryLocation(taskIdentifier: taskIdentifier)
        
        do {
            var target = asset.path
            try FileManager.default.moveItem(at: current, to: target)
            
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            
            try target.setResourceValues(resourceValues)
            
            try finishedDownloading(asset: asset)
        } catch {
            assetDownloadFailed(taskIdentifier: taskIdentifier)
        }
    }
    
    func reportProgress(taskID: Int, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let asset = asset(taskIdentifier: taskID) else {
            return
        }
        
        let id = asset.id
        let itemID = asset.itemID
        let progressWeight = asset.progressWeight
        
        Task {
            await RFNotification[.downloadProgressChanged(itemID)].send(payload: (id, progressWeight, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite))
        }
    }
    
    func beganDownloading(assetID: UUID, taskID: Int) throws {
        guard let asset = asset(for: assetID) else {
            throw PersistenceError.missing
        }
        
        asset.downloadTaskID = taskID
        try modelContext.save()
    }
    func assetDownloadFailed(taskIdentifier: Int) {
        let destination = PersistenceManager.DownloadSubsystem.temporaryLocation(taskIdentifier: taskIdentifier)
        try? FileManager.default.removeItem(at: destination)
        
        guard let asset = asset(taskIdentifier: taskIdentifier) else {
            logger.fault("Task failed and corresponding asset not found: \(taskIdentifier)")
            
            Task {
                await PersistenceManager.shared.download.scheduleUpdateTask()
                
            }
            return
        }
        
        logger.error("Task failed: \(taskIdentifier, privacy: .public) for asset: \(asset.id, privacy: .public)")
        
        asset.downloadTaskID = nil
        
        do {
            try modelContext.save()
        } catch {
            logger.fault("Failed to save context after task failure: \(error)")
        }
        
        let assetID = asset.id
        
        Task {
            do {
                if let failedAttempts = await PersistenceManager.shared.keyValue[.assetFailedAttempts(assetID: assetID, itemID: asset.itemID)] {
                    logger.info("Asset \(assetID, privacy: .public) failed to download \(failedAttempts + 1) times")
                    
                    if failedAttempts > ASSET_ATTEMPT_LIMIT {
                        logger.warning("Asset \(assetID, privacy: .public) failed to download more than 3 times. Removing download \(asset.itemID)")
                        try await remove(asset.itemID)
                    } else {
                        try await PersistenceManager.shared.keyValue.set(.assetFailedAttempts(assetID: assetID, itemID: asset.itemID), failedAttempts + 1)
                    }
                } else {
                    try await PersistenceManager.shared.keyValue.set(.assetFailedAttempts(assetID: assetID, itemID: asset.itemID), 1)
                }
            } catch {
                logger.error("Failed to update failed download attempts for asset \(assetID, privacy: .public): \(error)")
            }
            
            await PersistenceManager.shared.download.scheduleUpdateTask()
        }
    }
    func finishedDownloading(assetID: UUID) throws {
        guard let asset = asset(for: assetID) else {
            throw PersistenceError.missing
        }
        
        try finishedDownloading(asset: asset)
    }
    func finishedDownloading(asset: PersistedAsset) throws {
        asset.isDownloaded = true
        asset.downloadTaskID = nil
        
        try modelContext.save()
        
        logger.info("Finished downloading asset \(asset.id, privacy: .public) for \(asset.itemID, privacy: .public)")
        
        if fetchDownloadStatus(of: asset.itemID) == .completed {
            Task {
                await finishedDownloading(itemID: asset.itemID)
            }
        }
        
        scheduleUpdateTask()
    }
    func finishedDownloading(itemID: ItemIdentifier) async {
        do {
            try await PersistenceManager.shared.keyValue.set(.cachedDownloadStatus(itemID: itemID), .completed)
        } catch {
            logger.error("Failed to update download status for \(itemID) after it finished downloading: \(error)")
        }
        
        await RFNotification[.downloadStatusChanged].send(payload: (itemID, .completed))
    }
    
    nonisolated func scheduleUnfinishedForCompletion() async throws {
        let path = NWPathMonitor().currentPath
        
        if (path.isExpensive || path.isConstrained) && !Defaults[.allowCellularDownloads] {
            return
        }
        
        let tasks = await urlSession.tasks.2
        
        guard tasks.count < ACTIVE_TASK_LIMIT else {
            logger.info("There are \(tasks.count) active downloads. Skipping.")
            return
        }
        
        guard let (id, itemID, fileType) = await nextAsset else {
            return
        }
        
        try Task.checkCancellation()
        
        let request: URLRequest
        
        switch fileType {
        case .pdf(_, let ino):
            request = try await ABSClient[itemID.connectionID].pdfRequest(from: itemID, ino: ino)
        case .image(let size):
            guard let coverRequest = try? await ABSClient[itemID.connectionID].coverRequest(from: itemID, width: size.width) else {
                try await finishedDownloading(assetID: id)
                await scheduleUpdateTask()
                
                return
            }
            
            request = coverRequest
        case .audio(_, _, let ino, _):
            request = try await ABSClient[itemID.connectionID].audioTrackRequest(from: itemID, ino: ino)
        }
        
        let task = await urlSession.downloadTask(with: request)
        
        try await beganDownloading(assetID: id, taskID: task.taskIdentifier)
        task.resume()
        
        logger.info("Began downloading asset \(id) from item \(itemID)")
        
        await scheduleUpdateTask()
    }
    
    func removeEmptyPodcasts() async throws {
        guard let podcasts = try? modelContext.fetch(FetchDescriptor<PersistedPodcast>(predicate: #Predicate { $0.episodes.isEmpty })) else {
            return
        }
        
        for podcast in podcasts {
            try await remove(podcast.id)
        }
    }
    
    static func temporaryLocation(taskIdentifier: Int) -> URL {
        URL.temporaryDirectory.appending(path: "\(taskIdentifier).tmp")
    }
}

public extension PersistenceManager.DownloadSubsystem {
    subscript(itemID: ItemIdentifier) -> Item? {
        switch itemID.type {
        case .audiobook:
            if let audiobook = persistedAudiobook(for: itemID) {
                return Audiobook(downloaded: audiobook)
            }
        case .episode:
            if let episode = persistedEpisode(for: itemID) {
                return Episode(downloaded: episode)
            }
            
        case .podcast:
            if let podcast = persistedPodcast(for: itemID) {
                return Podcast(downloaded: podcast)
            }
        default:
            break
        }
        
        return nil
    }
    func item(primaryID: ItemIdentifier.PrimaryID, groupingID: ItemIdentifier.GroupingID?, connectionID: ItemIdentifier.ConnectionID) -> PlayableItem? {
        if let groupingID {
            let episodeType = ItemIdentifier.ItemType.episode.rawValue
            var episodeDescriptor = FetchDescriptor<PersistedEpisode>(predicate: #Predicate {
                $0._id.contains(primaryID)
                && $0._id.contains(groupingID)
                && $0._id.contains(connectionID)
                && $0._id.contains(episodeType)
            })
            episodeDescriptor.fetchLimit = 1
            
            guard let episode = (try? modelContext.fetch(episodeDescriptor))?.first else {
                return nil
            }
            
            return Episode(downloaded: episode)
        } else {
            let audiobookType = ItemIdentifier.ItemType.episode.rawValue
            var audiobookDescriptor = FetchDescriptor<PersistedAudiobook>(predicate: #Predicate {
                $0._id.contains(primaryID)
                && $0._id.contains(connectionID)
                && $0._id.contains(audiobookType)
            })
            audiobookDescriptor.fetchLimit = 1
            
            guard let audiobook = (try? modelContext.fetch(audiobookDescriptor))?.first else {
                return nil
            }
            
            return Audiobook(downloaded: audiobook)
        }
    }
    func podcast(primaryID: ItemIdentifier.PrimaryID, connectionID: ItemIdentifier.ConnectionID) -> Podcast? {
        let podcastType = ItemIdentifier.ItemType.podcast.rawValue
        
        var descriptor = FetchDescriptor<PersistedPodcast>(predicate: #Predicate {
            $0._id.contains(primaryID)
            && $0._id.contains(connectionID)
            && $0._id.contains(podcastType)
        })
        descriptor.fetchLimit = 1
        
        guard let podcast = (try? modelContext.fetch(descriptor))?.first else {
            return nil
        }
        
        return .init(downloaded: podcast)
    }
    
    func scheduleUpdateTask() {
        updateTask?.cancel()
        updateTask = .detached {
            do {
                try await self.scheduleUnfinishedForCompletion()
            } catch {
                self.logger.error("Failed to schedule unfinished for completion: \(error)")
            }
        }
    }
    
    func status(of itemID: ItemIdentifier) async -> DownloadStatus {
        guard itemID.isPlayable else {
            return .none
        }
        
        if let status = await PersistenceManager.shared.keyValue[.cachedDownloadStatus(itemID: itemID)] {
            if status == .none {
                do {
                    try await PersistenceManager.shared.keyValue.set(.cachedDownloadStatus(itemID: itemID), nil)
                } catch {
                    logger.error("Failed to clear cached download status: \(error)")
                }
            } else {
                return status
            }
        }
        
        let status = fetchDownloadStatus(of: itemID)
        
        // Should be cached already
        try? await PersistenceManager.shared.keyValue.set(.cachedDownloadStatus(itemID: itemID), status)
        
        return status
    }
    
    func downloadProgress(of itemID: ItemIdentifier) -> Percentage {
        (try? assets(for: itemID).filter { $0.isDownloaded }.reduce(0) { $0 + $1.progressWeight }) ?? 0
    }
    
    func cover(for itemID: ItemIdentifier, size: ImageSize) async -> URL? {
        if let cached = await PersistenceManager.shared.keyValue[.coverURLCache(itemID: itemID, size: size)] {
            if FileManager.default.fileExists(atPath: cached.path()) {
                return cached
            } else {
                return nil
            }
        }
        
        guard let assets = try? assets(for: itemID) else {
            return nil
        }
        
        let asset = assets.first {
            switch $0.fileType {
            case .image(let current):
                size == current
            default:
                false
            }
        }
        
        let path = asset?.path
        
        guard let path, FileManager.default.fileExists(atPath: path.path()) else {
            return nil
        }
        
        do {
            try await PersistenceManager.shared.keyValue.set(.coverURLCache(itemID: itemID, size: size), path)
        } catch {
            logger.error("Failed to cache cover URL for \(itemID) (\(size.base)): \(error)")
        }
        
        return path
    }
    func audioTracks(for itemID: ItemIdentifier) throws -> [PlayableItem.AudioTrack] {
        try assets(for: itemID).compactMap {
            switch $0.fileType {
            case .audio(let offset, let duration, _, _):
                    .init(offset: offset, duration: duration, resource: $0.path)
            default:
                nil
            }
        }
    }
    func chapters(itemID: ItemIdentifier) -> [Chapter] {
        do {
            return try modelContext.fetch(FetchDescriptor<PersistedChapter>(predicate: #Predicate {
                $0._itemID == itemID.description
            })).map { .init(id: $0.index, startOffset: $0.startOffset, endOffset: $0.endOffset, title: $0.name) }
        } catch {
            return []
        }
    }
    
    func audiobooks() throws -> [Audiobook] {
        return try modelContext.fetch(FetchDescriptor<PersistedAudiobook>()).map(Audiobook.init)
    }
    func audiobooks(in libraryID: String) throws -> [Audiobook] {
        return try modelContext.fetch(FetchDescriptor<PersistedAudiobook>(predicate: #Predicate {
            $0._id.contains(libraryID)
        })).filter { $0.id.libraryID == libraryID }.map(Audiobook.init)
    }
    
    func episodes() throws -> [Episode] {
        try modelContext.fetch(FetchDescriptor<PersistedEpisode>()).map(Episode.init)
    }
    func episodes(from podcastID: ItemIdentifier) throws -> [Episode] {
        guard podcastID.type == .podcast else {
            throw PersistenceError.unsupportedItemType
        }
        
        guard let podcast = persistedPodcast(for: podcastID) else {
            return []
        }
        
        return podcast.episodes.map(Episode.init)
    }
    
    func podcasts() throws -> [Podcast] {
        try modelContext.fetch(FetchDescriptor<PersistedPodcast>()).map(Podcast.init)
    }
    
    /// Performs the necessary work to add an item to the download queue.
    ///
    /// This method is atomic and progress tracking is available after it completes.
    func download(_ itemID: ItemIdentifier) async throws {
        guard itemID.isPlayable else {
            throw PersistenceError.unsupportedItemType
        }
        
        guard persistedAudiobook(for: itemID) == nil && persistedEpisode(for: itemID) == nil else {
            if await PersistenceManager.shared.keyValue[.cachedDownloadStatus(itemID: itemID)] == DownloadStatus.none {
                let status = await status(of: itemID)
                
                try await PersistenceManager.shared.keyValue.set(.cachedDownloadStatus(itemID: itemID), status)
                await RFNotification[.downloadStatusChanged].send(payload: (itemID, status))
                
            }
            
            throw PersistenceError.existing
        }
        
        guard !blocked.keys.contains(itemID) else {
            throw PersistenceError.blocked
        }
        
        guard !busy.contains(itemID) else {
            throw PersistenceError.busy
        }
        
        busy.insert(itemID)
        
        let task = await UIApplication.shared.beginBackgroundTask(withName: "download::\(itemID)")
        
        do {
            try await PersistenceManager.shared.keyValue.set(.cachedDownloadStatus(itemID: itemID), nil)
            
            // Download progress completed = all assets downloaded to 100%
            // Otherwise: 10% shared between pdfs
            // Otherwise: 10% shared between images
            // Otherwise: 80% shared between audio
            
            // Formula: category base * (1/n) where n = number of assets in category
            
            let (item, audioTracks, chapters, supplementaryPDFs) = try await ABSClient[itemID.connectionID].playableItem(itemID: itemID)
            
            var podcast: PersistedPodcast?
            
            if let episode = item as? Episode {
                podcast = persistedPodcast(for: episode.podcastID)
                
                if podcast == nil {
                    let podcastItem = try await ABSClient[itemID.connectionID].podcast(with: episode.podcastID).0
                    
                    podcast = .init(id: podcastItem.id,
                                    name: podcastItem.name,
                                    authors: podcastItem.authors,
                                    overview: podcastItem.description,
                                    genres: podcastItem.genres,
                                    addedAt: podcastItem.addedAt,
                                    released: podcastItem.released,
                                    explicit: podcastItem.explicit,
                                    publishingType: podcastItem.publishingType,
                                    totalEpisodeCount: podcastItem.episodeCount,
                                    episodes: [])
                    
                    let podcastAssets = ImageSize.allCases.map { PersistedAsset(itemID: podcastItem.id, fileType: .image(size: $0), progressWeight: 0) }
                    
                    for asset in podcastAssets {
                        modelContext.insert(asset)
                    }
                    
                    modelContext.insert(podcast!)
                    try modelContext.save()
                    
                    logger.info("Created podcast \(podcast!.name) for episode \(episode.name)")
                }
            }
            
            var assets = [PersistedAsset]()
            
            let individualCoverWeight = 0.1 * (1 / Double(ImageSize.allCases.count))
            let individualPDFWeight = 0.1 * (1 / Double(supplementaryPDFs.count))
            let individualAudioTrackWeight = 0.8 * (1 / Double(audioTracks.count))
            
            assets += ImageSize.allCases.map { .init(itemID: itemID, fileType: .image(size: $0), progressWeight: individualCoverWeight) }
            assets += supplementaryPDFs.map { .init(itemID: itemID, fileType: .pdf(name: $0.fileName, ino: $0.ino), progressWeight: individualPDFWeight) }
            assets += audioTracks.map { .init(itemID: itemID, fileType: .audio(offset: $0.offset, duration: $0.duration, ino: $0.ino, fileExtension: $0.fileExtension), progressWeight: individualAudioTrackWeight) }
            
            let model: any PersistentModel
            
            switch item {
            case is Audiobook:
                let audiobook = item as! Audiobook
                model = PersistedAudiobook(id: itemID,
                                           name: item.name,
                                           authors: item.authors,
                                           overview: item.description,
                                           genres: item.genres,
                                           addedAt: item.addedAt,
                                           released: item.released,
                                           size: item.size,
                                           duration: item.duration,
                                           subtitle: audiobook.subtitle,
                                           narrators: audiobook.narrators,
                                           series: audiobook.series,
                                           explicit: audiobook.explicit,
                                           abridged: audiobook.abridged)
            case is Episode:
                let episode = item as! Episode
                
                model = PersistedEpisode(id: itemID,
                                         name: item.name,
                                         authors: item.authors,
                                         overview: item.description,
                                         addedAt: item.addedAt,
                                         released: item.released,
                                         size: item.size,
                                         duration: item.duration,
                                         podcast: podcast!,
                                         type: episode.type,
                                         index: episode.index)
                
                podcast?.episodes.append(model as! PersistedEpisode)
            default:
                fatalError("Unsupported item type: \(type(of: item))")
            }
            
            try modelContext.transaction {
                for chapter in chapters {
                    modelContext.insert(PersistedChapter(index: chapter.id, itemID: itemID, name: chapter.title, startOffset: chapter.startOffset, endOffset: chapter.endOffset))
                }
                
                for asset in assets {
                    modelContext.insert(asset)
                }
                
                modelContext.insert(model)
            }
            try modelContext.save()
            
            busy.remove(itemID)
            
            logger.info("Created download for \(itemID)")
            
            await RFNotification[.downloadStatusChanged].send(payload: (itemID, .downloading))
            
            scheduleUpdateTask()
            
            await UIApplication.shared.endBackgroundTask(task)
        } catch {
            logger.error("Error creating download: \(error)")
            busy.remove(itemID)
            
            await UIApplication.shared.endBackgroundTask(task)
            
            throw error
        }
    }
    func remove(_ itemID: ItemIdentifier) async throws {
        guard itemID.type != .podcast else {
            guard let podcast = persistedPodcast(for: itemID) else {
                throw PersistenceError.missing
            }
            
            let episodes = try episodes(from: itemID)
            
            for episode in episodes {
                try await remove(episode.id)
            }
        
            try await removeAssets(assets(for: itemID))
            
            for coverSize in ImageSize.allCases {
                try await PersistenceManager.shared.keyValue.set(.coverURLCache(itemID: itemID, size: coverSize), nil)
            }
            
            modelContext.delete(podcast)
            try modelContext.save()
            
            return
        }
        
        guard itemID.isPlayable else {
            throw PersistenceError.unsupportedItemType
        }
        
        guard !blocked.keys.contains(itemID) else {
            throw PersistenceError.blocked
        }
        
        guard !busy.contains(itemID) else {
            throw PersistenceError.busy
        }
        
        busy.insert(itemID)
        
        do {
            if let model: any PersistentModel = persistedAudiobook(for: itemID) ?? persistedEpisode(for: itemID) {
                modelContext.delete(model)
            } else {
                logger.error("Tried to delete non-existent model for \(itemID)")
            }
            
            try modelContext.delete(model: SchemaV2.PersistedChapter.self, where: #Predicate { $0._itemID == itemID.description })
            
            let assets = try assets(for: itemID)
            
            try await PersistenceManager.shared.keyValue.set(.cachedDownloadStatus(itemID: itemID), nil)
            try await PersistenceManager.shared.keyValue.remove(cluster: "assetFailedAttempts_\(itemID.description)")
            
            for coverSize in ImageSize.allCases {
                try await PersistenceManager.shared.keyValue.set(.coverURLCache(itemID: itemID, size: coverSize), nil)
            }
            
            if !assets.isEmpty {
                try await removeAssets(assets)
            }
            
            try modelContext.save()
            
            await RFNotification[.downloadStatusChanged].send(payload: (itemID, .none))
            
            busy.remove(itemID)
            
            try await removeEmptyPodcasts()
        } catch {
            logger.error("Error removing download: \(error)")
            busy.remove(itemID)
            
            throw error
        }
    }
    func removeAll() async throws {
        do {
            try modelContext.delete(model: PersistedAudiobook.self)
            
            // try modelContext.delete(model: PersistedEpisode.self)
            // try modelContext.delete(model: PersistedPodcast.self)
            
            for episode in try episodes() {
                do {
                    try await remove(episode.id)
                } catch {
                    logger.error("Failed to remove episode \(episode.id): \(error)")
                }
            }
            
            try modelContext.delete(model: PersistedAsset.self)
            try modelContext.delete(model: PersistedChapter.self)
        } catch {
            logger.error("Failed to remove all downloads: \(error)")
        }
        
        do {
            let path = ShelfPlayerKit.downloadDirectoryURL
            try FileManager.default.removeItem(at: path)
        } catch {
            logger.error("Failed to remove download directory: \(error)")
        }
        
        await RFNotification[.downloadStatusChanged].send(payload: nil)
    }
    
    func addBlock(to itemID: ItemIdentifier) {
        if let existing = blocked[itemID] {
            blocked[itemID] = existing + 1
        } else {
            blocked[itemID] = 1
        }
    }
    func removeBlock(from itemID: ItemIdentifier) {
        guard let existing = blocked[itemID] else {
            logger.error("Tried to remove non existing block for item: \(itemID)")
            return
        }
        
        if existing == 1 {
            blocked[itemID] = nil
        } else {
            blocked[itemID] = existing - 1
        }
    }
    
    func invalidateActiveDownloads() {
        logger.info("Invalidating active downloads...")
        
        do {
            let assets = try modelContext.fetch(FetchDescriptor<PersistedAsset>(predicate: #Predicate { $0.downloadTaskID != nil }))
            
            for asset in assets {
                asset.downloadTaskID = nil
            }
        } catch {
            logger.error("Failed to fetch assets while invalidating active downloads: \(error)")
        }
        
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save context: \(error)")
        }
        
        Task {
            for task in await urlSession.tasks.2 {
                task.cancel()
            }
        }
        
        RFNotification[.downloadStatusChanged].dispatch(payload: nil)
    }
    
    func search(query: String) async throws -> [ItemIdentifier] {
        let descriptor = FetchDescriptor<SchemaV2.PersistedSearchIndexEntry>(predicate: #Predicate {
            $0.primaryName.localizedStandardContains(query)
            || $0.secondaryName?.localizedStandardContains(query) == true
            || $0.authorName.localizedStandardContains(query)
        })
        return try modelContext.fetch(descriptor).map(\.itemID)
    }
}

private final class URLSessionDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = PersistenceManager.DownloadSubsystem.temporaryLocation(taskIdentifier: downloadTask.taskIdentifier)
        
        try? FileManager.default.removeItem(at: destination)
        
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            PersistenceManager.shared.download.logger.error("Error moving downloaded file: \(error)")
            
            Task {
                await PersistenceManager.shared.download.assetDownloadFailed(taskIdentifier: downloadTask.taskIdentifier)
            }
            
            return
        }
        
        Task {
            await PersistenceManager.shared.download.handleCompletion(taskIdentifier: downloadTask.taskIdentifier)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            PersistenceManager.shared.download.logger.error("Download task \(task.taskIdentifier) failed: \(error)")
            
            Task {
                await PersistenceManager.shared.download.assetDownloadFailed(taskIdentifier: task.taskIdentifier)
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await PersistenceManager.shared.authorization.handleURLSessionChallenge(challenge)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task {
            await PersistenceManager.shared.download.reportProgress(taskID: downloadTask.taskIdentifier, bytesWritten: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }
    
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        Task {
            await PersistenceManager.shared.download.invalidateActiveDownloads()
        }
    }
}

private extension PersistenceManager.KeyValueSubsystem.Key {
    static func assetFailedAttempts(assetID: UUID, itemID: ItemIdentifier) -> Key<Int> {
        Key(identifier: "assetFailedAttempts_\(assetID)", cluster: "assetFailedAttempts_\(itemID.description)", isCachePurgeable: false)
    }
    static func cachedDownloadStatus(itemID: ItemIdentifier) -> Key<DownloadStatus> {
        Key(identifier: "downloadStatus_\(itemID)", cluster: "downloadStatusCache", isCachePurgeable: true)
    }
    
    static func coverURLCache(itemID: ItemIdentifier, size: ImageSize) -> Key<URL> {
        Key(identifier: "coverURL_\(itemID)_\(size)", cluster: "coverURLCache", isCachePurgeable: true)
    }
}
