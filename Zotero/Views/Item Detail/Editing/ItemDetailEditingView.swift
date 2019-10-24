//
//  ItemDetailEditingView.swift
//  Zotero
//
//  Created by Michal Rentka on 01/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct ItemDetailEditingView: View {
    @EnvironmentObject private(set) var store: ItemDetailStore

    var body: some View {
        Group {
            ItemDetailEditTitleView(title: self.$store.state.data.title)
            ItemDetailEditMetadataSectionView()
            ItemDetailEditNoteSectionView()
            ItemDetailEditTagSectionView()
            ItemDetailEditAttachmentSectionView()
        }
    }
}

struct ItemDetailEditingView_Previews: PreviewProvider {
    static var previews: some View {
        ItemDetailEditingView()
    }
}
