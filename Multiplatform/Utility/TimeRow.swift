//
//  TimeRow.swift
//  Multiplatform
//
//  Created by Rasmus Krämer on 20.05.25.
//

import SwiftUI

struct TimeRow: View {
    @Environment(Satellite.self) private var satellite

    let title: String
    let time: TimeInterval
    
    let isActive: Bool
    let isFinished: Bool
    
    let callback: () -> Void
    
    var body: some View {
        Button {
            callback()
        } label: {
            HStack(spacing: 0) {
                ZStack (alignment: .topLeading) {
                    Text(verbatim: "00:00:00")
                        .hidden()
                    
                    Text(time, format: .duration(unitsStyle: .positional, allowedUnits: [.hour, .minute, .second], maximumUnitCount: 3))
                }
                .font(.footnote)
                .fontDesign(.rounded)
                .foregroundStyle(Color.accentColor)
                .padding(.trailing, 12)
                
                Text(title)
                    .bold(isActive)
                    .foregroundStyle(isFinished ? .secondary : .primary)
                
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}

#if DEBUG
#Preview {
    List {
        TimeRow(title: "Test a really long line to see how it gets truncated even if its a really long bit of text that requires many lines of text it looks like its working", time: 300, isActive: false, isFinished: false) {}
        TimeRow(title: "Test", time: 300, isActive: false, isFinished: true) {}
        TimeRow(title: "Test", time: 300, isActive: true, isFinished: false) {}
        TimeRow(title: "Test", time: 300, isActive: true, isFinished: true) {}
    }
    .listStyle(.plain)
    .previewEnvironment()
}
#endif
