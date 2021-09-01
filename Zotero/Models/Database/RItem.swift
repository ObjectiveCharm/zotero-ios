//
//  RItem.swift
//  Zotero
//
//  Created by Michal Rentka on 07/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct RItemChanges: OptionSet {
    typealias RawValue = Int16

    let rawValue: Int16

    init(rawValue: Int16) {
        self.rawValue = rawValue
    }
}

extension RItemChanges {
    static let type = RItemChanges(rawValue: 1 << 0)
    static let trash = RItemChanges(rawValue: 1 << 1)
    static let parent = RItemChanges(rawValue: 1 << 2)
    static let collections = RItemChanges(rawValue: 1 << 3)
    static let fields = RItemChanges(rawValue: 1 << 4)
    static let tags = RItemChanges(rawValue: 1 << 5)
    static let creators = RItemChanges(rawValue: 1 << 6)
    static let relations = RItemChanges(rawValue: 1 << 7)
    static let rects = RItemChanges(rawValue: 1 << 8)
    static let paths = RItemChanges(rawValue: 1 << 9)
    static let all: RItemChanges = [.type, .trash, .parent, .collections, .fields, .tags, .creators, .relations]
}

final class RItem: Object {
    static let observableKeypathsForItemList: [String] = ["rawType", "baseTitle", "displayTitle", "sortTitle", "creatorSummary", "sortCreatorSummary", "hasCreatorSummary", "parsedDate",
                                                          "hasParsedDate", "parsedYear", "hasParsedYear", "publisher", "hasPublisher", "publicationTitle", "hasPublicationTitle"]

    @Persisted(indexed: true) var key: String
    @Persisted var rawType: String
    @Persisted var baseTitle: String
    @Persisted var inPublications: Bool
    @Persisted var dateAdded: Date
    @Persisted var dateModified: Date
    @Persisted var parent: RItem?
    @Persisted var createdBy: RUser?
    @Persisted var lastModifiedBy: RUser?
    @Persisted var customLibraryKey: Int?
    @Persisted var groupKey: Int?
    @Persisted(originProperty: "items") var collections: LinkingObjects<RCollection>
    @Persisted(originProperty: "item") var fields: LinkingObjects<RItemField>
    @Persisted(originProperty: "parent") var children: LinkingObjects<RItem>
    @Persisted(originProperty: "item") var tags: LinkingObjects<RTypedTag>
    @Persisted(originProperty: "item") var creators: LinkingObjects<RCreator>
    @Persisted(originProperty: "item") var links: LinkingObjects<RLink>
    @Persisted(originProperty: "item") var relations: LinkingObjects<RRelation>

    // MARK: - Attachment data
    @Persisted var backendMd5: String
    @Persisted var mainAttachment: RItem?
    @Persisted var fileDownloaded: Bool
    // MARK: - Annotation data
    @Persisted var rects: List<RRect>
    @Persisted var paths: List<RPath>
    // MARK: - Derived data
    /// Localized type based on current localization of device, used for sorting
    @Persisted var localizedType: String
    /// Title which is displayed in items list
    @Persisted var displayTitle: String
    /// Title by which the item list is sorted
    @Persisted var sortTitle: String
    /// Summary of creators collected from linked RCreators
    @Persisted var creatorSummary: String?
    /// Summary of creators used for sorting
    @Persisted var sortCreatorSummary: String?
    /// Indicates whether this instance has nonempty creatorSummary, helper variable, used in sorting so that we can show items with summaries
    /// first and sort them in any order we want (asd/desc) and all other items later
    @Persisted var hasCreatorSummary: Bool
    /// Date that was parsed from "date" field
    @Persisted var parsedDate: Date?
    /// Indicates whether this instance has nonempty parsedDate, helper variable, used in sorting so that we can show items with dates
    /// first and sort them in any order we want (asd/desc) and all other items later
    @Persisted var hasParsedDate: Bool
    /// Year that was parsed from "date" field
    @Persisted var parsedYear: Int
    /// Indicates whether this instance has nonempty parsedYear, helper variable, used in sorting so that we can show items with years
    /// first and sort them in any order we want (asd/desc) and all other items later
    @Persisted var hasParsedYear: Bool
    /// Value taken from publisher field
    @Persisted var publisher: String?
    /// Indicates whether this instance has nonempty publisher, helper variable, used in sorting so that we can show items with publishers
    /// first and sort them in any order we want (asd/desc) and all other items later
    @Persisted var hasPublisher: Bool
    /// Value taken from publicationTitle field
    @Persisted var publicationTitle: String?
    /// Indicates whether this instance has nonempty publicationTitle, helper variable, used in sorting so that we can show items with titles
    /// first and sort them in any order we want (asd/desc) and all other items later
    @Persisted var hasPublicationTitle: Bool
    /// Sort index for annotations
    @Persisted var annotationSortIndex: String
    // MARK: - Sync data
    /// Indicates whether the object is trashed locally and needs to be synced with backend
    @Persisted var trash: Bool
    /// Indicates local version of object
    @Persisted(indexed: true) var version: Int
    /// Indicates whether attachemnt (file) needs to be uploaded to backend
    @Persisted var attachmentNeedsSync: Bool
    /// State which indicates whether object is synced with backend data, see ObjectSyncState for more info
    @Persisted var rawSyncState: Int
    /// Date when last sync attempt was performed on this object
    @Persisted var lastSyncDate: Date
    /// Number of retries for sync of this object
    @Persisted var syncRetries: Int
    /// Raw value for OptionSet of changes for this object, indicates which local changes need to be synced to backend
    @Persisted var rawChangedFields: Int16
    /// Raw value for `UpdatableChangeType`, indicates whether current update of item has been made by user or sync process.
    @Persisted var rawChangeType: Int
    /// Indicates whether the object is deleted locally and needs to be synced with backend
    @Persisted var deleted: Bool

    var attachment: RItem? {
        if self.rawType == ItemTypes.attachment {
            return self
        }
        return self.mainAttachment
    }

    var doi: String? {
        return self.fields.filter(.key(FieldKeys.Item.doi)).first.flatMap({ field -> String? in
            let doi = FieldKeys.Item.clean(doi: field.value)
            return !doi.isEmpty ? doi : nil
        })
    }

    var urlString: String? {
        return self.fields.filter(.key(FieldKeys.Item.url)).first?.value
    }

    // MARK: - Sync properties

    var changedFields: RItemChanges {
        get {
            return RItemChanges(rawValue: self.rawChangedFields)
        }

        set {
            self.rawChangedFields = newValue.rawValue
        }
    }

    // MARK: - Helpers

    func set(title: String) {
        self.baseTitle = title
        self.updateDerivedTitles()
    }

    func set(publicationTitle: String?) {
        self.publicationTitle = publicationTitle?.lowercased()
        self.hasPublicationTitle = publicationTitle?.isEmpty == false
    }

    func set(publisher: String?) {
        self.publisher = publisher?.lowercased()
        self.hasPublisher = publisher?.isEmpty == false
    }

    func updateDerivedTitles() {
        let displayTitle = ItemTitleFormatter.displayTitle(for: self)
        if self.displayTitle != displayTitle {
            self.displayTitle = displayTitle
        }
        self.updateSortTitle()
    }

    private func updateSortTitle() {
        let newTitle = self.displayTitle.trimmingCharacters(in: CharacterSet(charactersIn: "[]'\"")).lowercased()
        if newTitle != self.sortTitle {
            self.sortTitle = newTitle
        }
    }

    func setDateFieldMetadata(_ date: String?, parser: DateParser) {
        let components = date.flatMap({ parser.parse(string: $0) })
        self.parsedYear = components?.year ?? 0
        self.hasParsedYear = self.parsedYear != 0
        self.parsedDate = components?.date
        self.hasParsedDate = self.parsedDate != nil
    }

    func updateCreatorSummary() {
        self.creatorSummary = CreatorSummaryFormatter.summary(for: self.creators.filter("primary = true"))
        self.sortCreatorSummary = self.creatorSummary?.lowercased()
        self.hasCreatorSummary = self.creatorSummary != nil
    }

    /// Chooses main attachment in the following order:
    /// - oldest PDF attachment matching parent URL,
    /// - oldest PDF attachment not matching parent URL,
    func updateMainAttachment() {
        guard self.parent == nil else {
            self.mainAttachment = nil
            return
        }

        let attachments = self.children.filter(.items(type: ItemTypes.attachment, notSyncState: .dirty, trash: false))
                                       .sorted(byKeyPath: "dateAdded", ascending: true)
                                       .filter({ attachment in
                                           let linkMode = attachment.fields.filter(.key(FieldKeys.Item.Attachment.linkMode)).first?.value
                                           return linkMode == "imported_file" || linkMode == "imported_url"
                                       })
                                       .filter({ $0.fields.filter(.key(FieldKeys.Item.Attachment.contentType)).first?.value == "application/pdf" })

        guard attachments.count > 0 else {
            self.mainAttachment = nil
            return
        }

        let url = self.fields.filter(.key(FieldKeys.Item.Attachment.url)).first?.value

        if let url = url, let matchingUrl = attachments.first(where: { $0.fields.filter(.key(FieldKeys.Item.Attachment.url)).first?.value == url }) {
            self.mainAttachment = matchingUrl
            return
        }

        self.mainAttachment = attachments.first
    }
}

final class RItemField: Object {
    @Persisted var key: String
    @Persisted var baseKey: String?
    @Persisted var value: String
    @Persisted var item: RItem?
    @Persisted var changed: Bool
}
