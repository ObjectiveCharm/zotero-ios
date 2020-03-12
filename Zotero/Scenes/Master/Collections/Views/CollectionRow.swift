//
//  CollectionRow.swift
//  Zotero
//
//  Created by Michal Rentka on 20/08/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct CollectionRow: View {
    static let levelOffset: CGFloat = 20.0
    let data: Collection

    var body: some View {
        GeometryReader { proxy in
            HStack {
                Image(self.data.iconName)
                    .renderingMode(.template)
                    .foregroundColor(.blue)
                Text(self.data.name)
                    .foregroundColor(.black)
                    .lineLimit(1)

                Spacer()

                if self.shouldShowCount {
                    Text("\(self.data.itemCount)")
                        .font(.caption)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            Rectangle()
                                .foregroundColor(Color.gray.opacity(0.2))
                                .cornerRadius(proxy.size.height/2.0)
                        )
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, self.inset(for: self.data.level))
            .padding(.trailing, 8)
            .frame(width: proxy.size.width, alignment: .leading)
        }
    }

    private var shouldShowCount: Bool {
        if self.data.itemCount == 0 {
            return false
        }

        if Defaults.shared.showCollectionItemCount {
            return true
        }

        switch self.data.type {
        case .custom(let type):
            return type == .all
        case .collection, .search:
            return false
        }
    }

    private func inset(for level: Int) -> CGFloat {
        let offset = CollectionRow.levelOffset
        return offset + (CGFloat(level) * offset)
    }
}

#if DEBUG

struct CollectionRow_Previews: PreviewProvider {
    static var previews: some View {
        List {
            CollectionRow(data: Collection(custom: .all, itemCount: 48))
            CollectionRow(data: Collection(custom: .publications, itemCount: 2))
            CollectionRow(data: Collection(custom: .trash, itemCount: 4))
        }
    }
}

#endif
