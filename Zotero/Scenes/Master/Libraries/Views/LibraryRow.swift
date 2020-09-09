//
//  LibraryRow.swift
//  Zotero
//
//  Created by Michal Rentka on 18/09/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct LibraryRow: View {
    let title: String
    let isReadOnly: Bool

    var body: some View {
        HStack(spacing: (self.isReadOnly ? 6 : 8)) {
            Image(self.isReadOnly ? Asset.Images.Cells.libraryReadonly.name : Asset.Images.Cells.library.name)
                .renderingMode(.template)
                .foregroundColor(Asset.Colors.zoteroBlue.swiftUiColor)
                .padding(EdgeInsets(top: 0, leading: (self.isReadOnly ? -2 : 0), bottom: 0, trailing: 0))
            Text(self.title)
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }
}

struct LibraryRow_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            List {
                LibraryRow(title: "My library", isReadOnly: false)
            }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}
