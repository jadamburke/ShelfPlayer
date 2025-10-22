//
//  ConnectionManageView.swift
//  Multiplatform
//
//  Created by Rasmus Krämer on 02.01.25.
//

import SwiftUI
import OSLog
import ShelfPlayback

struct ConnectionManageView: View {
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(Satellite.self) private var satellite
    @Environment(\.dismiss) private var dismiss
    
    let connection: FriendlyConnection
    
    @State private var isLoading = false
    @State private var status: (String, [AuthorizationStrategy], Bool)?
    
    @State private var isUsingLegacyAuthentication = false
    
    var body: some View {
        List {
            Section {
                Text(connection.username)
                Text(connection.host, format: .url)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(connectionStore.offlineConnections.contains(connection.id) ? .red : .primary)
            }
            
            Section {
                if let status {
                    Text("connection.test.success.message \(status.0)")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .task {
                            status = try? await ABSClient[connection.id].status()
                        }
                }
                
                OutdatedServerRow(version: status?.0)
                
                if isUsingLegacyAuthentication {
                    Text("connection.legacyAuthorization")
                        .foregroundStyle(.orange)
                }
            }
            
            #if DEBUG
            Section {
                Button {
                    Task {
                        try await PersistenceManager.shared.authorization.scrambleAccessToken(connectionID: connection.id)
                    }
                } label: {
                    Text(verbatim: "Scramble access token")
                }
                Button {
                    Task {
                        try await PersistenceManager.shared.authorization.scrambleRefreshToken(connectionID: connection.id)
                    }
                } label: {
                    Text(verbatim: "Scramble refresh token")
                }
            }
            #endif
            
            Section {
                Button("action.edit") {
                    satellite.present(.editConnection(connection.id))
                }
                Button("connection.reauthorize") {
                    satellite.present(.reauthorizeConnection(connection.id))
                }
                .disabled(status == nil)
                
                Button("connection.remove") {
                    Self.remove(connectionID: connection.id, isLoading: $isLoading) {
                        dismiss()
                    }
                }
                .foregroundStyle(.red)
            }
            .disabled(isLoading)
        }
        .navigationTitle("connection.manage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isUsingLegacyAuthentication = await PersistenceManager.shared.authorization.isUsingLegacyAuthentication(for: connection.id)
        }
        .task {
            status = try? await ABSClient[connection.id].status()
        }
    }
    
    static func remove(connectionID: ItemIdentifier.ConnectionID, isLoading: Binding<Bool>, callback: @escaping () -> Void) {
        Task {
            isLoading.wrappedValue = true
            
            await PersistenceManager.shared.remove(connectionID: connectionID)
            callback()
            
            isLoading.wrappedValue = false
        }
    }
}

#if DEBUG
#Preview {
    ConnectionManageView(connection: .fixture)
        .previewEnvironment()
}
#endif
