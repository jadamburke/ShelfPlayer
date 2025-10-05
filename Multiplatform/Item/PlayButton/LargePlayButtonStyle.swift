//
//  LargePlayButtonStyle.swift
//  Multiplatform
//
//  Created by Rasmus Krämer on 29.01.25.
//

import SwiftUI
import ShelfPlayback

struct LargePlayButtonStyle: PlayButtonStyle {
    func makeMenu(configuration: Configuration) -> some View {
        configuration.content
            .background {
                ZStack {
                    RFKVisuals.adjust(configuration.background, saturation: 0, brightness: -0.8)
                        .animation(.smooth, value: configuration.background)
                    
                    GeometryReader { geometry in
                        Rectangle()
                            .fill((configuration.background.isLight ?? false) ? .black : .white)
                            .opacity(0.14)
                            .frame(width: geometry.size.width * (1 - (configuration.progress ?? 0)))
                            .padding(.leading, geometry.size.width * (configuration.progress ?? 0))
                            .animation(.smooth, value: configuration.progress)
                    }
                }
            }
    }
    
    func makeLabel(configuration: Configuration) -> some View {
        configuration.content
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
    
    var tint: Bool {
        true
    }
    var cornerRadius: CGFloat {
        .infinity
    }
    var hideRemainingWhenUnplayed: Bool {
        true
    }
}

#if DEBUG
#Preview {
    PlayButton(item: Audiobook.fixture)
        .playButtonSize(.large)
        .previewEnvironment()
}

#Preview {
    PlayButton(item: Audiobook.fixture)
        .playButtonSize(.large)
        .previewEnvironment()
}
#endif
