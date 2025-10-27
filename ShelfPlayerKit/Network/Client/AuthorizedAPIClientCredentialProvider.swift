//
//  AuthorizedAPIClientCredentialProvider.swift
//  ShelfPlayer
//
//  Created by Rasmus Krämer on 17.08.25.
//

import Foundation
import OSLog

final actor AuthorizedAPIClientCredentialProvider: APICredentialProvider {
    let logger = Logger(subsystem: "com.jadamburke.shelfPlayerKit", category: "AuthorizedAPIClientCredentialProvider")
    
    let connectionID: ItemIdentifier.ConnectionID
    
    var token: String?
    var configuration: (URL, [HTTPHeader])
    
    var knownExpiredTokens: Set<String> = []
    
    var accessToken: String? {
        token
    }
    
    var shouldPostAuthorizationFailure: Bool {
        true
    }
    
    init(connectionID: ItemIdentifier.ConnectionID) async throws {
        self.connectionID = connectionID
        
        token = try? await PersistenceManager.shared.authorization.accessToken(for: connectionID)
        configuration = try await PersistenceManager.shared.authorization.configuration(for: connectionID)
    }
    
    func refreshAccessToken(current: String?) async throws -> String? {
        guard let token else {
            throw APIClientError.unauthorized
        }
        
        guard !knownExpiredTokens.contains(token) else {
            return nil
        }
        
        if token == current {
            knownExpiredTokens.insert(token)
            
            logger.info("Access token for \(self.connectionID) expired. Refreshing...")
            self.token = try await PersistenceManager.shared.authorization.refreshAccessToken(for: connectionID, current: token)
        }
        
        return self.token
    }
}
