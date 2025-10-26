//
//  Item+Fixture.swift
//  Audiobooks
//
//  Created by Rasmus Krämer on 03.10.23.
//

import Foundation

#if DEBUG
public extension Audiobook {
    static let fixture = Audiobook(
        id: .init(primaryID: "fixture-audiobook", groupingID: nil, libraryID: "fixture", connectionID: "fixture", type: .audiobook),
        name: "1984",
        authors: ["George Orwell"],
        description: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Sed vulputate odio ut enim. Cras semper auctor neque vitae. Tortor vitae purus faucibus ornare suspendisse. Sed vulputate mi sit amet mauris. Morbi leo urna molestie at elementum eu facilisis. Condimentum vitae sapien pellentesque habitant morbi tristique senectus. Viverra ipsum nunc aliquet bibendum enim. Aliquet nec ullamcorper sit amet risus nullam eget felis eget. Feugiat nibh sed pulvinar proin. Mauris rhoncus aenean vel elit. Metus vulputate eu scelerisque felis imperdiet proin fermentum leo vel. Integer enim neque volutpat ac tincidunt vitae semper. Vitae tortor condimentum lacinia quis vel eros donec ac. Ornare aenean euismod elementum nisi quis eleifend quam adipiscing vitae. Interdum posuere lorem ipsum dolor sit amet consectetur. Mattis molestie a iaculis at erat pellentesque. Sed faucibus turpis in eu. Elit eget gravida cum sociis natoque penatibus et. Nisi quis eleifend quam adipiscing vitae proin.",
        genres: ["Horror", "Science-Fiction"],
        tags:["Aliens","Dystopia"],
        addedAt: Date(),
        released: "1900",
        size: 999_999_999,
        duration: 60 * 60 * 12,
        subtitle: "Now your reality",
        narrators: ["Steven Fry"],
        series: [Audiobook.SeriesFragment(id: .init(primaryID: "fixture", groupingID: nil, libraryID: "fixture", connectionID: "fixture", type: .series), name: "George Orwell Collection", sequence: 1)],
        explicit: true,
        abridged: true)
}
#endif
