//
//  AnnotationViewTextView.swift
//  Zotero
//
//  Created by Michal Rentka on 20.11.2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

class AnnotationViewTextView: UIView {
    private weak var label: UILabel!
    private weak var textView: AnnotationTextView!
    private weak var topInsetConstraint: NSLayoutConstraint!

    private let layout: AnnotationViewLayout
    private let placeholder: String

    private var textViewDelegate: GrowingTextViewCellDelegate!
    var textObservable: Observable<(NSAttributedString, Bool)> {
        return self.textViewDelegate.textObservable
    }

    // MARK: - Lifecycle

    init(layout: AnnotationViewLayout, placeholder: String) {
        self.layout = layout
        self.placeholder = placeholder

        super.init(frame: CGRect())

        self.translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = layout.backgroundColor
        self.setupView()
        self.setupTextViewDelegate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Actions

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        return self.textView.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        return self.textView.resignFirstResponder()
    }

    // MARK: - Setups

    func setup(text: NSAttributedString?, halfTopInset: Bool) {
        self.label.attributedText = text
        if let text = text, !text.string.isEmpty {
            self.textView.textColor = .black
            self.textView.attributedText = text
        } else {
            self.textView.textColor = .lightGray
            self.textView.text = self.placeholder
        }

        let topFontOffset = self.layout.font.ascender - self.layout.font.xHeight
        let topInset = halfTopInset ? (self.layout.verticalSpacerHeight / 2) : self.layout.verticalSpacerHeight
        self.topInsetConstraint.constant = topInset - topFontOffset
    }

    private func setupView() {
        let label = UILabel()
        label.font = self.layout.font
        label.numberOfLines = 0
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true

        let textView = AnnotationTextView(defaultFont: self.layout.font)
        textView.textContainerInset = UIEdgeInsets()
        textView.textContainer.lineFragmentPadding = 0
        textView.text = self.placeholder
        textView.textColor = .lightGray
        textView.isScrollEnabled = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(textView)
        self.addSubview(label)

        let topFontOffset = self.layout.font.ascender - self.layout.font.xHeight
        let topInset = label.topAnchor.constraint(equalTo: self.topAnchor, constant: self.layout.verticalSpacerHeight - topFontOffset)

        if let minHeight = self.layout.commentMinHeight {
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        }

        NSLayoutConstraint.activate([
            // Horizontal
            label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: self.layout.horizontalInset),
            self.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: self.layout.horizontalInset),
            textView.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            // Vertical
            topInset,
            self.bottomAnchor.constraint(equalTo: label.lastBaselineAnchor, constant: self.layout.verticalSpacerHeight),
            textView.topAnchor.constraint(equalTo: label.topAnchor),
            textView.bottomAnchor.constraint(equalTo: label.bottomAnchor)
        ])

        self.label = label
        self.textView = textView
        self.topInsetConstraint = topInset
    }

    private func setupTextViewDelegate() {
        let bold = UIMenuItem(title: "Bold", action: #selector(UITextView.toggleBoldface(_:)))
        let italics = UIMenuItem(title: "Italics", action: #selector(UITextView.toggleItalics(_:)))
        let superscript = UIMenuItem(title: "Superscript", action: #selector(AnnotationTextView.toggleSuperscript))
        let `subscript` = UIMenuItem(title: "Subscript", action: #selector(AnnotationTextView.toggleSubscript))
        let items = [bold, italics, superscript, `subscript`]
        let delegate = GrowingTextViewCellDelegate(label: self.label, placeholder: self.placeholder, menuItems: items)
        self.textView.delegate = delegate
        self.textViewDelegate = delegate
    }
}

fileprivate class AnnotationTextView: UITextView {
    private static let allowedActions: [String] = ["cut:", "copy:", "paste:", "toggleBoldface:", "toggleItalics:", "toggleSuperscript", "toggleSubscript"]

    private let defaultFont: UIFont

    init(defaultFont: UIFont) {
        self.defaultFont = defaultFont
        super.init(frame: CGRect(), textContainer: nil)
        self.font = defaultFont
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return AnnotationTextView.allowedActions.contains(action.description)
    }

    @objc func toggleSuperscript() {
        guard self.selectedRange.length > 0 else { return }
        self.perform(attributedStringAction: { StringAttribute.toggleSuperscript(in: $0, range: $1, defaultFont: self.defaultFont) })
    }

    @objc func toggleSubscript() {
        guard self.selectedRange.length > 0 else { return }
        self.perform(attributedStringAction: { StringAttribute.toggleSubscript(in: $0, range: $1, defaultFont: self.defaultFont) })
    }

    private func perform(attributedStringAction: (NSMutableAttributedString, NSRange) -> Void) {
        let range = self.selectedRange
        let string = NSMutableAttributedString(attributedString: self.attributedText)
        attributedStringAction(string, range)
        self.attributedText = string
        self.selectedRange = range
        self.delegate?.textViewDidChange?(self)
    }
}
