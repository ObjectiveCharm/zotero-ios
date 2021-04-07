//
//  ItemDetailAbstractEditCell.swift
//  Zotero
//
//  Created by Michal Rentka on 23/10/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

final class ItemDetailAbstractEditCell: RxTableViewCell {
    @IBOutlet private weak var separatorHeight: NSLayoutConstraint!
    @IBOutlet private weak var titleLabel: UILabel!
    @IBOutlet private weak var contentTextView: UITextView!
    @IBOutlet private weak var titleTop: NSLayoutConstraint!
    @IBOutlet private weak var titleToContent: NSLayoutConstraint!
    @IBOutlet private weak var contentBottom: NSLayoutConstraint!

    private static let textViewTapAreaOffset: CGFloat = 8

    private var observer: AnyObserver<String>?
    var textObservable: Observable<String> {
        return Observable.create { observer -> Disposable in
            self.observer = observer
            return Disposables.create()
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        self.separatorHeight.constant = ItemDetailLayout.separatorHeight

        let titleFont = UIFont.preferredFont(for: .headline, weight: .regular)
        self.titleLabel.font = titleFont
        self.titleTop.constant = -(titleFont.ascender - titleFont.capHeight)
        let contentFont = UIFont.preferredFont(forTextStyle: .body)
        self.titleToContent.constant = contentFont.ascender - (ItemDetailLayout.lineHeight - contentFont.capHeight) - ItemDetailAbstractEditCell.textViewTapAreaOffset
        self.contentBottom.constant = contentFont.descender - ItemDetailLayout.separatorHeight - 1 - ItemDetailAbstractEditCell.textViewTapAreaOffset

        self.contentTextView.delegate = self
        self.contentTextView.isScrollEnabled = false
        self.contentTextView.textContainerInset = UIEdgeInsets(top: ItemDetailAbstractEditCell.textViewTapAreaOffset, left: 0, bottom: ItemDetailAbstractEditCell.textViewTapAreaOffset, right: 0)
        self.contentTextView.textContainer.lineFragmentPadding = 0
    }

    func setup(with abstract: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.minimumLineHeight = ItemDetailLayout.lineHeight
        paragraphStyle.maximumLineHeight = ItemDetailLayout.lineHeight

        let attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraphStyle,
                                                         .font: UIFont.preferredFont(forTextStyle: .body)]
        let attributedText = NSAttributedString(string: abstract, attributes: attributes)

        self.contentTextView.attributedText = attributedText
    }
}

extension ItemDetailAbstractEditCell: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        self.observer?.on(.next(textView.text))
    }
}
