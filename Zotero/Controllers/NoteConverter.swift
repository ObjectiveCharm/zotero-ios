//
//  NoteConverter.swift
//  Zotero
//
//  Created by Michal Rentka on 01/07/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

class NoteConverter {
    private struct Attribute {
        fileprivate enum Kind {
            case b, i, sup, sub
        }

        let type: Kind
        let index: Int
        let isClosing: Bool
    }

    private struct AttributedContent {
        let attributes: [Attribute.Kind]
        let startIndex: Int
        let length: Int
    }

    private struct Tag {
        let type: Attribute.Kind
        let startIndex: Int
        let endIndex: Int
        let deletedCount: Int
        let closed: Bool

        func copy(closed: Bool) -> Tag {
            return Tag(type: self.type,
                       startIndex: self.startIndex,
                       endIndex: self.endIndex,
                       deletedCount: self.deletedCount,
                       closed: closed)
        }
    }

    func convert(attributedString: NSAttributedString) -> String {
        // TODO
        return ""
    }

    func convert(comment: String, baseFont: UIFont) -> NSAttributedString {
        var tagStart: Int?
        var deletedCharacters = 0
        var tags: [Tag] = []
        var attributes: [Attribute] = []

        // Find tags and attributed content

        for (index, character) in comment.enumerated() {
            if character == "<" {
                tagStart = index
                continue
            }

            guard character == ">", let start = tagStart else { continue }

            let tagStartIndex = comment.index(comment.startIndex, offsetBy: (start + 1))
            let tagEndIndex = comment.index(comment.startIndex, offsetBy: index)
            let tag = comment[tagStartIndex..<tagEndIndex]
            let strippedTag = self.stripClosingCharacter(in: tag)

            guard let type = self.attributeType(from: (strippedTag ?? tag)) else {
                // If tag is not recognized, ignore
                tagStart = nil
                continue
            }

            guard strippedTag != nil else {
                // Opening tag
                tags.insert(Tag(type: type, startIndex: start, endIndex: index, deletedCount: deletedCharacters, closed: false), at: 0)
                deletedCharacters += tag.count + 2 // + '<', '>'
                tagStart = nil
                continue
            }

            // Closing tag

            guard let openingTagIndex = tags.firstIndex(where: { !$0.closed && $0.type == type }) else {
                // If opening tag is not found, ignore closing tag
                tagStart = nil
                continue
            }

            let openingTag = tags[openingTagIndex].copy(closed: true)
            let closingTag = Tag(type: type, startIndex: start, endIndex: index, deletedCount: deletedCharacters, closed: true)

            tags[openingTagIndex] = openingTag
            tags.insert(closingTag, at: 0)

            attributes.append(Attribute(type: type, index: (openingTag.startIndex - openingTag.deletedCount), isClosing: false))
            attributes.append(Attribute(type: type, index: (closingTag.startIndex - deletedCharacters), isClosing: true))

            deletedCharacters += tag.count + 2 // + '<', '>'
            tagStart = nil
        }

        // Strip tags from comment
        var strippedComment = comment
        for tag in tags {
            let start = strippedComment.index(strippedComment.startIndex, offsetBy: tag.startIndex)
            let end = strippedComment.index(strippedComment.startIndex, offsetBy: tag.endIndex)
            strippedComment.removeSubrange(start...end)
        }

        attributes.sort(by: { $0.index < $1.index })

        // Split overlaying ranges into unique ranges with multiple attribute kinds
        var splitRanges: [AttributedContent] = []
        var activeAttributes: [Attribute.Kind] = []

        for (index, attribute) in attributes.enumerated() {
            guard index < attributes.count - 1 else { break }

            if attribute.isClosing {
                // If attribute was closed, remove it from active attributes
                if let index = activeAttributes.firstIndex(of: attribute.type) {
                    activeAttributes.remove(at: index)
                }
            } else {
                // If attribute was opened, add it to active attributes
                activeAttributes.append(attribute.type)
            }

            let nextAttribute = attributes[index + 1]

            if attribute.index <= nextAttribute.index && !activeAttributes.isEmpty {
                let length = nextAttribute.index - attribute.index
                guard length > 0 else { continue }
                splitRanges.append(AttributedContent(attributes: activeAttributes, startIndex: attribute.index, length: length))
            }
        }

        // Create mutable attributed string, apply attributed content
        let attributedString = NSMutableAttributedString(string: strippedComment, attributes: [.font: baseFont])
        for content in splitRanges {
            attributedString.addAttributes(self.attributes(from: content.attributes, baseFont: baseFont),
                                           range: NSMakeRange(content.startIndex, content.length))
        }

        return attributedString
    }

    private func stripClosingCharacter(in tag: Substring) -> Substring? {
        if tag.first == "/" {
            return tag[tag.index(tag.startIndex, offsetBy: 1)..<tag.endIndex]
        }

        if tag.last == "/" {
            return tag[tag.startIndex..<tag.index(tag.endIndex, offsetBy: -1)]
        }

        return nil
    }

    private func attributeType(from tag: Substring) -> Attribute.Kind? {
        switch tag {
        case "b":
            return .b
        case "i":
            return .i
        case "sup":
            return .sup
        case "sub":
            return .sub
        default:
            return nil
        }
    }

    private func attributes(from attributeTypes: [Attribute.Kind], baseFont: UIFont) -> [NSAttributedString.Key: Any] {
        var allKeys: [NSAttributedString.Key: Any] = [:]
        var font = baseFont
        var traits: UIFontDescriptor.SymbolicTraits = []

        for attribute in attributeTypes {
            switch attribute {
            case .b:
                if !traits.contains(.traitBold) {
                    traits.insert(.traitBold)
                }

            case .i:
                if !traits.contains(.traitItalic) {
                    traits.insert(.traitItalic)
                }

            case .sub:
                let offset = font.pointSize * 0.2
                font = font.size(font.pointSize * 0.75)
                let baseline = (allKeys[.baselineOffset] as? CGFloat) ?? 0
                allKeys[.baselineOffset] = baseline - offset

            case .sup:
                let offset = font.pointSize * 0.4
                font = font.size(font.pointSize * 0.75)
                let baseline = (allKeys[.baselineOffset] as? CGFloat) ?? 0
                allKeys[.baselineOffset] = baseline + offset
            }
        }

        if traits.isEmpty {
            allKeys[.font] = font
        } else {
            allKeys[.font] = font.withTraits(traits)
        }

        return allKeys
    }
}
