//
//  CreateAnnotationsDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 31.08.2022.
//  Copyright © 2022 Corporation for Digital Scholarship. All rights reserved.
//

#if PDFENABLED

import UIKit

import RealmSwift

struct CreateAnnotationsDbRequest: DbRequest {
    let attachmentKey: String
    let libraryId: LibraryIdentifier
    let annotations: [DocumentAnnotation]

    unowned let schemaController: SchemaController
    unowned let boundingBoxConverter: AnnotationBoundingBoxConverter

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws {
        guard let parent = database.objects(RItem.self).filter(.key(self.attachmentKey, in: self.libraryId)).first else { return }

        for annotation in self.annotations {
            guard database.objects(RItem.self).filter(.key(annotation.key, in: self.libraryId)).first == nil else { continue }
            self.create(annotation: annotation, parent: parent, in: database)
        }
    }

    private func create(annotation: DocumentAnnotation, parent: RItem, in database: Realm) {
        let item = RItem()
        item.key = annotation.key
        item.rawType = ItemTypes.annotation
        item.localizedType = self.schemaController.localized(itemType: ItemTypes.annotation) ?? ""
        item.syncState = .synced
        item.changeType = .user
        // We need to submit tags on creation even if they are empty, so we need to mark them as changed
        item.changedFields = [.parent, .fields, .type, .tags]
        item.dateAdded = annotation.dateModified
        item.dateModified = annotation.dateModified
        item.libraryId = self.libraryId
        database.add(item)

        item.parent = parent

        self.addFields(for: annotation, to: item, database: database)
        self.add(rects: annotation.rects, to: item, database: database)
        self.add(paths: annotation.paths, to: item, database: database)
    }

    private func addFields(for annotation: Annotation, to item: RItem, database: Realm) {
        for field in FieldKeys.Item.Annotation.fields(for: annotation.type) {
            let rField = RItemField()
            rField.key = field.key
            rField.baseKey = field.baseKey
            rField.changed = true

            switch field.key {
            case FieldKeys.Item.Annotation.type:
                rField.value = annotation.type.rawValue
            case FieldKeys.Item.Annotation.color:
                rField.value = annotation.color
            case FieldKeys.Item.Annotation.comment:
                rField.value = annotation.comment
            case FieldKeys.Item.Annotation.Position.pageIndex where field.baseKey == FieldKeys.Item.Annotation.position:
                rField.value = "\(annotation.page)"
            case FieldKeys.Item.Annotation.Position.lineWidth where field.baseKey == FieldKeys.Item.Annotation.position:
                rField.value = annotation.lineWidth.flatMap({ "\(Decimal($0).rounded(to: 3))" }) ?? ""
            case FieldKeys.Item.Annotation.pageLabel:
                rField.value = annotation.pageLabel
            case FieldKeys.Item.Annotation.sortIndex:
                rField.value = annotation.sortIndex
                item.annotationSortIndex = annotation.sortIndex
            case FieldKeys.Item.Annotation.text:
                rField.value = annotation.text ?? ""
            default: break
            }

            item.fields.append(rField)
        }
    }

    private func add(rects: [CGRect], to item: RItem, database: Realm) {
        guard !rects.isEmpty else { return }
        for rect in rects {
            let rRect = RRect()
            rRect.minX = Double(rect.minX)
            rRect.minY = Double(rect.minY)
            rRect.maxX = Double(rect.maxX)
            rRect.maxY = Double(rect.maxY)
            item.rects.append(rRect)
        }
        item.changedFields.insert(.rects)
    }

    private func add(paths: [[CGPoint]], to item: RItem, database: Realm) {
        guard !paths.isEmpty else { return }

        for (idx, path) in paths.enumerated() {
            let rPath = RPath()
            rPath.sortIndex = idx

            for (idy, point) in path.enumerated() {
                let rXCoordinate = RPathCoordinate()
                rXCoordinate.value = Double(point.x)
                rXCoordinate.sortIndex = idy * 2
                rPath.coordinates.append(rXCoordinate)

                let rYCoordinate = RPathCoordinate()
                rYCoordinate.value = Double(point.y)
                rYCoordinate.sortIndex = (idy * 2) + 1
                rPath.coordinates.append(rYCoordinate)
            }

            item.paths.append(rPath)
        }

        item.changedFields.insert(.paths)
    }
}

#endif
