//
//  ItemDetailEditingView.swift
//  Zotero
//
//  Created by Michal Rentka on 01/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct ItemDetailEditingView: View {
    @EnvironmentObject var store: ItemDetailStore

    var body: some View {
        List {
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
