//
//  ItemDetailStore.swift
//  Zotero
//
//  Created by Michal Rentka on 19/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation
import UIKit

import CocoaLumberjack
import RealmSwift
import RxSwift

enum ItemDetailError: Error, Equatable, Identifiable, Hashable {
    case schemaNotInitialized, typeNotSupported, libraryNotAssigned,
         contentTypeUnknown, userMissing, downloadError, unknown,
         cantStoreChanges
    case fileNotCopied(Int)
    case droppedFields([String])

    var id: Int {
        return self.hashValue
    }
}

struct ItemDetailDataCreator {
    static func createData(from type: ItemDetailState.DetailType, schemaController: SchemaController, fileStorage: FileStorage) throws -> ItemDetailState.Data {
        switch type {
        case .creation:
            return try creationData(schemaController: schemaController)
        case .preview(let item), .duplication(let item, _):
            return try itemData(item: item, schemaController: schemaController, fileStorage: fileStorage)
        }
    }

    private static func creationData(schemaController: SchemaController) throws -> ItemDetailState.Data {
        guard let itemType = schemaController.itemTypes.sorted().first,
              let localizedType = schemaController.localized(itemType: itemType) else {
            throw ItemDetailError.schemaNotInitialized
        }

        let (fieldIds, fields, hasAbstract) = try fieldData(for: itemType, schemaController: schemaController)
        let date = Date()

        return ItemDetailState.Data(title: "",
                                    type: itemType,
                                    localizedType: localizedType,
                                    creators: [:],
                                    creatorIds: [],
                                    fields: fields,
                                    fieldIds: fieldIds,
                                    abstract: (hasAbstract ? "" : nil),
                                    notes: [],
                                    attachments: [],
                                    tags: [],
                                    dateModified: date,
                                    dateAdded: date)
    }

    private static func itemData(item: RItem, schemaController: SchemaController, fileStorage: FileStorage) throws -> ItemDetailState.Data {
        guard let localizedType = schemaController.localized(itemType: item.rawType) else {
            throw ItemDetailError.typeNotSupported
        }

        var abstract: String?
        var values: [String: String] = [:]

        item.fields.forEach { field in
            switch field.key {
            case FieldKeys.abstract:
                abstract = field.value
            default:
                values[field.key] = field.value
            }
        }

        let (fieldIds, fields, _) = try fieldData(for: item.rawType, schemaController: schemaController, getExistingData: { key, _ in
            return (nil, values[key])
        })

        var creatorIds: [UUID] = []
        var creators: [UUID: ItemDetailState.Creator] = [:]
        for creator in item.creators.sorted(byKeyPath: "orderId") {
            guard let localizedType = schemaController.localized(creator: creator.rawType) else { continue }

            let creator = ItemDetailState.Creator(firstName: creator.firstName,
                                                  lastName: creator.lastName,
                                                  fullName: creator.name,
                                                  type: creator.rawType,
                                                  primary: schemaController.creatorIsPrimary(creator.rawType, itemType: item.rawType),
                                                  localizedType: localizedType)
            creatorIds.append(creator.id)
            creators[creator.id] = creator
        }

        let notes = item.children.filter(.items(type: ItemTypes.note, notSyncState: .dirty, trash: false))
                                 .sorted(byKeyPath: "displayTitle")
                                 .compactMap(ItemDetailState.Note.init)
        let attachments: [Attachment]
        if item.rawType == ItemTypes.attachment {
            let attachment = self.attachmentType(for: item, fileStorage: fileStorage).flatMap({ Attachment(item: item, type: $0) })
            attachments = attachment.flatMap { [$0] } ?? []
        } else {
            let mappedAttachments = item.children.filter(.items(type: ItemTypes.attachment, notSyncState: .dirty, trash: false))
                                                 .sorted(byKeyPath: "displayTitle")
                                                 .compactMap({ item -> Attachment? in
                                                     return attachmentType(for: item, fileStorage: fileStorage)
                                                                        .flatMap({ Attachment(item: item, type: $0) })
                                                 })
            attachments = Array(mappedAttachments)
        }

        let tags = item.tags.sorted(byKeyPath: "name").map(Tag.init)

        return ItemDetailState.Data(title: item.baseTitle,
                                    type: item.rawType,
                                    localizedType: localizedType,
                                    creators: creators,
                                    creatorIds: creatorIds,
                                    fields: fields,
                                    fieldIds: fieldIds,
                                    abstract: abstract,
                                    notes: Array(notes),
                                    attachments: attachments,
                                    tags: Array(tags),
                                    dateModified: item.dateModified,
                                    dateAdded: item.dateAdded)
    }

    fileprivate static func fieldData(for itemType: String, schemaController: SchemaController,
                                  getExistingData: ((String, String?) -> (String?, String?))? = nil) throws -> ([String], [String: ItemDetailState.Field], Bool) {
        guard var fieldSchemas = schemaController.fields(for: itemType) else {
            throw ItemDetailError.typeNotSupported
        }

        var fieldKeys = fieldSchemas.map({ $0.field })
        let abstractIndex = fieldKeys.firstIndex(of: FieldKeys.abstract)

        // Remove title and abstract keys, those 2 are used separately in Data struct
        if let index = abstractIndex {
            fieldKeys.remove(at: index)
            fieldSchemas.remove(at: index)
        }
        if let key = schemaController.titleKey(for: itemType), let index = fieldKeys.firstIndex(of: key) {
            fieldKeys.remove(at: index)
            fieldSchemas.remove(at: index)
        }

        var fields: [String: ItemDetailState.Field] = [:]
        for (offset, key) in fieldKeys.enumerated() {
            let baseField = fieldSchemas[offset].baseField
            let (existingName, existingValue) = (getExistingData?(key, baseField) ?? (nil, nil))

            let name = existingName ?? schemaController.localized(field: key) ?? ""
            let value = existingValue ?? ""

            fields[key] = ItemDetailState.Field(key: key,
                                                baseField: baseField,
                                                name: name,
                                                value: value,
                                                isTitle: false)
        }

        return (fieldKeys, fields, (abstractIndex != nil))
    }

    private static func attachmentType(for item: RItem, fileStorage: FileStorage) -> Attachment.ContentType? {
        let contentType = item.fields.filter(.key(FieldKeys.contentType)).first?.value ?? ""
        if !contentType.isEmpty { // File attachment
            if let ext = contentType.extensionFromMimeType,
               let libraryId = item.libraryObject?.identifier {
                let filename = item.fields.filter(.key(FieldKeys.filename)).first?.value ?? (item.displayTitle + "." + ext)
                let file = Files.objectFile(for: .item, libraryId: libraryId, key: item.key, ext: ext)
                let isLocal = fileStorage.has(file)
                return .file(file: file, filename: filename, isLocal: isLocal)
            } else {
                DDLogError("Attachment: mimeType/extension unknown (\(contentType)) for item (\(item.key))")
                return nil
            }
        } else { // Some other attachment (url, etc.)
            if let urlString = item.fields.filter("key = %@", "url").first?.value,
               let url = URL(string: urlString) {
                return .url(url)
            } else {
                DDLogError("Attachment: unknown attachment, fields: \(item.fields.map({ $0.key }))")
                return nil
            }
        }
    }

    fileprivate static func allFieldKeys(for itemType: String, schemaController: SchemaController) -> [String] {
        guard let fieldSchemas = schemaController.fields(for: itemType) else { return [] }
        var fieldKeys = fieldSchemas.map({ $0.field })
        // Remove title and abstract keys, those 2 are used separately in Data struct
        if let index = fieldKeys.firstIndex(of: FieldKeys.abstract) {
            fieldKeys.remove(at: index)
        }
        if let key = schemaController.titleKey(for: itemType), let index = fieldKeys.firstIndex(of: key) {
            fieldKeys.remove(at: index)
        }
        return fieldKeys
    }

    fileprivate static func filteredFieldKeys(from fieldKeys: [String], fields: [String: ItemDetailState.Field]) -> [String] {
        var newFieldKeys: [String] = []
        fieldKeys.forEach { key in
            if !(fields[key]?.value ?? "").isEmpty {
                newFieldKeys.append(key)
            }
        }
        return newFieldKeys
    }
}

struct ItemDetailState: ViewModelState {
    enum DetailType {
        case creation(libraryId: LibraryIdentifier, collectionKey: String?, filesEditable: Bool)
        case duplication(RItem, collectionKey: String?)
        case preview(RItem)

        var isCreation: Bool {
            switch self {
            case .preview:
                return false
            case .creation, .duplication:
                return true
            }
        }
    }

    struct Field: Identifiable, Equatable, Hashable {
        let key: String
        let baseField: String?
        var name: String
        var value: String
        let isTitle: Bool

        var id: String { return self.key }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.key)
            hasher.combine(self.value)
        }
    }

    struct Note: Identifiable, Equatable {
        let key: String
        var title: String
        var text: String

        var id: String { return self.key }

        init(key: String, text: String) {
            self.key = key
            self.title = text.strippedHtml ?? text
            self.text = text
        }

        init?(item: RItem) {
            guard item.rawType == ItemTypes.note else {
                DDLogError("Trying to create Note from RItem which is not a note!")
                return nil
            }

            self.key = item.key
            self.title = item.displayTitle
            self.text = item.fields.filter(.key(FieldKeys.note)).first?.value ?? ""
        }
    }

    struct Creator: Identifiable, Equatable, Hashable {
        enum NamePresentation: Equatable {
            case separate, full

            mutating func toggle() {
                self = self == .full ? .separate : .full
            }
        }

        var type: String
        var primary: Bool
        var localizedType: String
        var fullName: String
        var firstName: String
        var lastName: String
        var namePresentation: NamePresentation {
            willSet {
                self.change(namePresentation: newValue)
            }
        }

        var name: String {
            if !self.fullName.isEmpty {
                return self.fullName
            }

            guard !self.firstName.isEmpty || !self.lastName.isEmpty else { return "" }

            var name = self.lastName
            if !self.lastName.isEmpty {
                name += ", "
            }
            return name + self.firstName
        }

        var isEmpty: Bool {
            return self.fullName.isEmpty && self.firstName.isEmpty && self.lastName.isEmpty
        }

        let id: UUID

        init(firstName: String, lastName: String, fullName: String, type: String, primary: Bool, localizedType: String) {
            self.id = UUID()
            self.type = type
            self.primary = primary
            self.localizedType = localizedType
            self.fullName = fullName
            self.firstName = firstName
            self.lastName = lastName
            self.namePresentation = fullName.isEmpty ? .separate : .full
        }

        init(type: String, primary: Bool, localizedType: String) {
            self.id = UUID()
            self.type = type
            self.primary = primary
            self.localizedType = localizedType
            self.fullName = ""
            self.firstName = ""
            self.lastName = ""
            self.namePresentation = .full
        }

        mutating func change(namePresentation: NamePresentation) {
            guard namePresentation != self.namePresentation else { return }

            switch namePresentation {
            case .full:
                self.fullName = self.firstName + (self.firstName.isEmpty ? "" : " ") + self.lastName
                self.firstName = ""
                self.lastName = ""
            case .separate:
                if self.fullName.isEmpty {
                    self.firstName = ""
                    self.lastName = ""
                    return
                }

                if !self.fullName.contains(" ") {
                    self.lastName = self.fullName
                    self.firstName = ""
                    return
                }

                let components = self.fullName.components(separatedBy: " ")
                self.firstName = components.dropLast().joined(separator: " ")
                self.lastName = components.last ?? ""
            }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.type)
            hasher.combine(self.primary)
            hasher.combine(self.fullName)
            hasher.combine(self.firstName)
            hasher.combine(self.lastName)
        }
    }

    struct Data: Equatable {
        var title: String
        var type: String
        var localizedType: String
        var creators: [UUID: Creator]
        var creatorIds: [UUID]
        var fields: [String: Field]
        var fieldIds: [String]
        var abstract: String?
        var notes: [Note]
        var attachments: [Attachment]
        var tags: [Tag]

        var dateModified: Date
        let dateAdded: Date

        var maxFieldTitleWidth: CGFloat = 0
        var maxNonemptyFieldTitleWidth: CGFloat = 0

        func databaseFields(schemaController: SchemaController) -> [Field] {
            var allFields = Array(self.fields.values)

            if let titleKey = schemaController.titleKey(for: self.type) {
                allFields.append(Field(key: titleKey,
                                       baseField: (titleKey != FieldKeys.title ? FieldKeys.title : nil),
                                       name: "",
                                       value: self.title,
                                       isTitle: true))
            }

            if let abstract = self.abstract {
                allFields.append(Field(key: FieldKeys.abstract,
                                       baseField: nil,
                                       name: "",
                                       value: abstract,
                                       isTitle: false))
            }


            return allFields
        }

        mutating func recalculateMaxTitleWidth() {
            var maxTitle = ""
            var maxNonEmptyTitle = ""

            self.fields.values.forEach { field in
                if field.name.count > maxTitle.count {
                    maxTitle = field.name
                }

                if !field.value.isEmpty && field.name.count > maxNonEmptyTitle.count {
                    maxNonEmptyTitle = field.name
                }
            }

            // TODO: - localize
            let extraFields = ["Item Type", "Date Modified", "Date Added", "Abstract"] + self.creators.values.map({ $0.localizedType })
            extraFields.forEach { name in
                if name.count > maxTitle.count {
                    maxTitle = name
                }
                if name.count > maxNonEmptyTitle.count {
                    maxNonEmptyTitle = name
                }
            }

            self.maxFieldTitleWidth = ceil(maxTitle.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]).width)
            self.maxNonemptyFieldTitleWidth = ceil(maxNonEmptyTitle.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]).width)
        }
    }

    let libraryId: LibraryIdentifier
    let userId: Int
    let metadataEditable: Bool
    let filesEditable: Bool

    var isEditing: Bool
    var type: DetailType
    var data: Data
    var snapshot: Data?
    var promptSnapshot: Data?
    var downloadProgress: [String: Double]
    var downloadError: [String: ItemDetailError]
    var error: ItemDetailError?
    var presentedNote: Note
    var metadataTitleMaxWidth: CGFloat

    init(type: DetailType, userId: Int, data: Data, error: ItemDetailError? = nil) {
        self.userId = userId
        self.type = type
        self.data = data
        self.downloadProgress = [:]
        self.downloadError = [:]
        self.metadataTitleMaxWidth = 0
        self.error = error
        self.presentedNote = Note(key: KeyGenerator.newKey, text: "")

        switch type {
        case .preview(let item), .duplication(let item, _):
            self.isEditing = false
            self.libraryId = item.libraryObject?.identifier ?? .custom(.myLibrary)
            self.snapshot = nil
            // Item has either grouop assigned with canEditMetadata or it's a custom library which is always editable
            self.metadataEditable = item.group?.canEditMetadata ?? true
            // Item has either grouop assigned with canEditFiles or it's a custom library which is always editable
            self.filesEditable = item.group?.canEditFiles ?? true
            // Filter fieldIds to show only non-empty values
            self.data.fieldIds = ItemDetailDataCreator.filteredFieldKeys(from: self.data.fieldIds, fields: self.data.fields)
        case .creation(let libraryId, _, let filesEditable):
            self.isEditing = true
            self.libraryId = libraryId
            self.snapshot = data
            // Since we're in creation mode editing must have beeen enabled
            self.metadataEditable = true
            self.filesEditable = filesEditable
        }
    }

    init(type: DetailType, userId: Int, error: ItemDetailError) {
        self.init(type: type,
                  userId: userId,
                  data: Data(title: "", type: "", localizedType: "",
                             creators: [:], creatorIds: [],
                             fields: [:], fieldIds: [],
                             abstract: nil, notes: [],
                             attachments: [], tags: [],
                             dateModified: Date(), dateAdded: Date()),
                  error: error)
    }

    func cleanup() {}
}

enum ItemDetailAction {
    case acceptPrompt
    case addAttachments([URL])
    case addCreator
    case addNote
    case cancelEditing
    case cancelPrompt
    case changeType(String)
    case deleteAttachments(IndexSet)
    case deleteCreators(IndexSet)
    case deleteNotes(IndexSet)
    case deleteTags(IndexSet)
    case moveCreators(from: IndexSet, to: Int)
    case openNote(ItemDetailState.Note)
    case saveNote(String)
    case setTags([Tag])
    case save
    case startEditing
}

struct ItemDetailActionHandler: ViewModelActionHandler {
    typealias State = ItemDetailState
    typealias Action = ItemDetailAction

    private let apiClient: ApiClient
    private let fileStorage: FileStorage
    private let dbStorage: DbStorage
    private let schemaController: SchemaController
    private let disposeBag: DisposeBag

    init(apiClient: ApiClient, fileStorage: FileStorage,
         dbStorage: DbStorage, schemaController: SchemaController) {
        self.apiClient = apiClient
        self.fileStorage = fileStorage
        self.dbStorage = dbStorage
        self.schemaController = schemaController
        self.disposeBag = DisposeBag()
    }

    func process(action: ItemDetailAction, in viewModel: ViewModel<ItemDetailActionHandler>) {
        switch action {
        case .changeType(let type):
            self.changeType(to: type, in: viewModel)

        case .acceptPrompt:
            self.acceptPromptSnapshot(in: viewModel)

        case .cancelPrompt:
            self.update(viewModel: viewModel) { state in
                state.promptSnapshot = nil
            }

        case .addAttachments(let urls):
            self.addAttachments(from: urls, in: viewModel)

        case .deleteAttachments(let offsets):
            self.update(viewModel: viewModel) { state in
                state.data.attachments.remove(atOffsets: offsets)
            }

        case .addCreator:
            self.addCreator(in: viewModel)

        case .deleteCreators(let offsets):
            self.deleteCreators(at: offsets, in: viewModel)

        case .moveCreators(let from, let to):
            self.update(viewModel: viewModel) { state in
                state.data.creatorIds.move(fromOffsets: from, toOffset: to)
            }

        case .addNote:
            self.update(viewModel: viewModel) { state in
                state.presentedNote = State.Note(key: KeyGenerator.newKey, text: "")
            }

        case .openNote(let note):
            self.update(viewModel: viewModel) { state in
                state.presentedNote = note
            }

        case .deleteNotes(let offsets):
            self.update(viewModel: viewModel) { state in
                state.data.notes.remove(atOffsets: offsets)
            }

        case .saveNote(let text):
            self.saveNote(text: text, in: viewModel)

        case .setTags(let tags):
            self.update(viewModel: viewModel) { state in
                state.data.tags = tags
            }

        case .deleteTags(let offsets):
            self.update(viewModel: viewModel) { state in
                state.data.tags.remove(atOffsets: offsets)
            }

        case .startEditing:
            self.startEditing(in: viewModel)

        case .cancelEditing:
            self.cancelChanges(in: viewModel)

        case .save:
            self.saveChanges(in: viewModel)
        }
    }

    // MARK: - Type

    private func changeType(to newType: String, in viewModel: ViewModel<ItemDetailActionHandler>) {
        do {
            let data = try self.data(for: newType, from: viewModel.state.data)
            self.set(data: data, in: viewModel)
        } catch let error {
            self.update(viewModel: viewModel) { state in
                state.error = (error as? ItemDetailError) ?? .typeNotSupported
            }
        }
    }

    private func set(data: ItemDetailState.Data, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let newFieldNames = Set(data.fields.values.map({ $0.name }))
        let oldFieldNames = Set(viewModel.state.data.fields.values.filter({ !$0.value.isEmpty }).map({ $0.name }))
        let droppedNames = oldFieldNames.subtracting(newFieldNames).sorted()

        guard droppedNames.isEmpty else {
            self.update(viewModel: viewModel) { state in
                state.promptSnapshot = data
                state.error = .droppedFields(droppedNames)
            }
            return
        }

        self.update(viewModel: viewModel) { state in
            state.data = data
        }
    }

    private func data(for type: String, from originalData: ItemDetailState.Data) throws -> ItemDetailState.Data {
        guard let localizedType = self.schemaController.localized(itemType: type) else {
            throw ItemDetailError.typeNotSupported
        }

        let (fieldIds, fields, hasAbstract) = try ItemDetailDataCreator.fieldData(for: type,
                                                                                  schemaController: self.schemaController,
                                                                                  getExistingData: { key, baseField -> (String?, String?) in
            if let field = originalData.fields[key] {
                return (field.name, field.value)
            } else if let base = baseField, let field = originalData.fields.values.first(where: { $0.baseField == base }) {
                // We don't return existing name, because fields that are matching just by baseField will most likely have different names
                return (nil, field.value)
            }
            return (nil, nil)
        })

        var data = originalData
        data.type = type
        data.localizedType = localizedType
        data.fields = fields
        data.fieldIds = fieldIds
        data.abstract = hasAbstract ? (originalData.abstract ?? "") : nil
        data.creators = try self.creators(for: type, from: originalData.creators)
        data.creatorIds = originalData.creatorIds
        data.recalculateMaxTitleWidth()

        return data
    }

    private func creators(for type: String, from originalData: [UUID: ItemDetailState.Creator]) throws -> [UUID: ItemDetailState.Creator] {
        guard let schemas = self.schemaController.creators(for: type),
              let primary = schemas.first(where: { $0.primary }) else { throw ItemDetailError.typeNotSupported }

        var creators = originalData
        for (key, originalCreator) in originalData {
            guard !schemas.contains(where: { $0.creatorType == originalCreator.type }) else { continue }

            var creator = originalCreator

            if originalCreator.primary {
                creator.type = primary.creatorType
            } else {
                creator.type = "contributor"
            }
            creator.localizedType = self.schemaController.localized(creator: creator.type) ?? ""

            creators[key] = creator
        }

        return creators
    }

    private func acceptPromptSnapshot(in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard let snapshot = viewModel.state.promptSnapshot else { return }
        self.update(viewModel: viewModel) { state in
            state.promptSnapshot = nil
            state.data = snapshot
        }
    }

    // MARK: - Creators

    private func addCreator(in viewModel: ViewModel<ItemDetailActionHandler>) {
        // Check whether there already is an empty/new creator, add only if there is none
        guard viewModel.state.data.creators.values.first(where: { $0.isEmpty }) == nil,
              let schema = self.schemaController.creators(for: viewModel.state.data.type)?.first(where: { $0.primary }),
              let localized = self.schemaController.localized(creator: schema.creatorType) else { return }

        let creator = State.Creator(type: schema.creatorType, primary: schema.primary, localizedType: localized)
        self.update(viewModel: viewModel) { state in
            state.data.creatorIds.append(creator.id)
            state.data.creators[creator.id] = creator
        }
    }

    private func deleteCreators(at offsets: IndexSet, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let keys = offsets.map({ viewModel.state.data.creatorIds[$0] })
        self.update(viewModel: viewModel) { state in
            state.data.creatorIds.remove(atOffsets: offsets)
            keys.forEach({ state.data.creators[$0] = nil })
        }
    }

    // MARK: - Notes

    private func saveNote(text: String, in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            var note = state.presentedNote
            note.text = text
            note.title = text.strippedHtml ?? ""

            if !state.isEditing {
                // Note was edited outside of editing mode, so it needs to be saved immediately
                do {
                    try self.saveNoteChanges(note, libraryId: state.libraryId)
                } catch let error {
                    DDLogError("ItemDetailStore: can't store note - \(error)")
                    state.error = .cantStoreChanges
                    return
                }
            }

            if let index = state.data.notes.firstIndex(where: { $0.key == note.key }) {
                state.data.notes[index] = note
            } else {
                state.data.notes.append(note)
            }
        }
    }

    private func saveNoteChanges(_ note: ItemDetailState.Note, libraryId: LibraryIdentifier) throws {
        let request = StoreNoteDbRequest(note: note, libraryId: libraryId)
        try self.dbStorage.createCoordinator().perform(request: request)
    }

    // MARK: - Attachments

    private func addAttachments(from urls: [URL], in viewModel: ViewModel<ItemDetailActionHandler>) {
        var errors = 0

        for url in urls {
            let originalFile = Files.file(from: url)
            let key = KeyGenerator.newKey
            let file = Files.objectFile(for: .item,
                                        libraryId: viewModel.state.libraryId,
                                        key: key,
                                        ext: originalFile.ext)
            let attachment = Attachment(key: key,
                                        title: originalFile.name,
                                        type: .file(file: file, filename: originalFile.name, isLocal: true),
                                        libraryId: viewModel.state.libraryId)

            do {
                try self.fileStorage.move(from: originalFile, to: file)

                let index = viewModel.state.data.attachments.index(of: attachment, sortedBy: { $0.title.caseInsensitiveCompare($1.title) == .orderedAscending })
                self.update(viewModel: viewModel) { state in
                    state.data.attachments.insert(attachment, at: index)
                }
            } catch let error {
                DDLogError("ItemDertailStore: can't copy attachment - \(error)")
                errors += 1
            }
        }

        if errors > 0 {
            self.update(viewModel: viewModel) { state in
                state.error = .fileNotCopied(errors)
            }
        }
    }

    private func openAttachment(_ attachment: Attachment, in viewModel: ViewModel<ItemDetailActionHandler>) {
        switch attachment.type {
        case .url(let url):
            NotificationCenter.default.post(name: .presentWeb, object: url)
        case .file(let file, _, let isCached):
            if isCached {
                self.openFile(file)
            } else {
                self.cacheFile(file, key: attachment.key, in: viewModel)
            }
        }
    }

    private func cacheFile(_ file: File, key: String, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let request = FileRequest(data: .internal(viewModel.state.libraryId, viewModel.state.userId, key), destination: file)
        self.apiClient.download(request: request)
                      .flatMap { request in
                          return request.rx.progress()
                      }
                      .observeOn(MainScheduler.instance)
                      .subscribe(onNext: { [weak viewModel] progress in
                          guard let viewModel = viewModel else { return }
                          let progress = progress.totalBytes == 0 ? 0 : Double(progress.bytesWritten) / Double(progress.totalBytes)
                          self.update(viewModel: viewModel) { state in
                              state.downloadProgress[key] = progress
                          }
                      }, onError: { [weak viewModel] error in
                          guard let viewModel = viewModel else { return }
                          self.finishCachingFile(for: key, result: .failure(error), in: viewModel)
                      }, onCompleted: { [weak viewModel] in
                          guard let viewModel = viewModel else { return }
                          self.finishCachingFile(for: key, result: .success(()), in: viewModel)
                      })
                      .disposed(by: self.disposeBag)
    }

    private func finishCachingFile(for key: String, result: Result<(), Swift.Error>, in viewModel: ViewModel<ItemDetailActionHandler>) {
        switch result {
        case .failure(let error):
            DDLogError("ItemDetailStore: show attachment - can't download file - \(error)")
            self.update(viewModel: viewModel) { state in
                state.downloadError[key] = .downloadError
            }

        case .success:
            self.update(viewModel: viewModel) { state in
                state.downloadProgress[key] = nil
                if let (index, attachment) = state.data.attachments.enumerated().first(where: { $1.key == key }) {
                    state.data.attachments[index] = attachment.changed(isLocal: true)
                    self.openAttachment(attachment, in: viewModel)
                }
            }
        }
    }

    private func openFile(_ file: File) {
        switch file.ext {
        case "pdf":
            #if PDFENABLED
            NotificationCenter.default.post(name: .presentPdf, object: file.createUrl())
            #endif
        default:
            NotificationCenter.default.post(name: .presentUnknownAttachment, object: file.createUrl())
        }
    }

    // MARK: - Editing

    private func startEditing(in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            state.snapshot = state.data
            state.data.fieldIds = ItemDetailDataCreator.allFieldKeys(for: state.data.type, schemaController: self.schemaController)
            state.isEditing = true
        }
    }

    func cancelChanges(in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard let snapshot = viewModel.state.snapshot else { return }
        self.update(viewModel: viewModel) { state in
            state.data = snapshot
            state.snapshot = nil
            state.isEditing = false
        }
    }

    func saveChanges(in viewModel: ViewModel<ItemDetailActionHandler>) {
        if viewModel.state.snapshot != viewModel.state.data {
            self._saveChanges(in: viewModel)
        }
    }

    private func _saveChanges(in viewModel: ViewModel<ItemDetailActionHandler>) {
        // TODO: - move to background thread if possible
        // SWIFTUI BUG: - sync store with environment .editMode so that we can switch edit mode when background task finished

        // TODO: - add loading indicator for saving

        self.save(state: viewModel.state)
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { [weak viewModel] newState in
                guard let viewModel = viewModel else { return }
                self.update(viewModel: viewModel) { state in
                    state = newState
                }
            }, onError: { [weak viewModel] error in
                DDLogError("ItemDetailStore: can't store changes - \(error)")
                guard let viewModel = viewModel else { return }
                self.update(viewModel: viewModel) { state in
                    state.error = (error as? ItemDetailError) ?? .cantStoreChanges
                }
            })
            .disposed(by: self.disposeBag)
    }

    private func save(state: ItemDetailState) -> Single<ItemDetailState> {
        return Single.create { subscriber -> Disposable in
            do {
                try self.fileStorage.copyAttachmentFilesIfNeeded(for: state.data.attachments)

                var newState = state
                var newType: State.DetailType?

                self.updateDateFieldIfNeeded(in: &newState)
                newState.data.dateModified = Date()

                switch state.type {
                case .preview(let item):
                    if let snapshot = state.snapshot {
                        try self.updateItem(key: item.key, libraryId: state.libraryId, data: state.data, snapshot: snapshot)
                    }

                case .creation(_, let collectionKey, _), .duplication(_, let collectionKey):
                    let item = try self.createItem(with: state.libraryId, collectionKey: collectionKey, data: state.data)
                    newType = .preview(item)
                }

                newState.snapshot = nil
                if let type = newType {
                    newState.type = type
                }
                newState.isEditing = false
                newState.data.fieldIds = ItemDetailDataCreator.filteredFieldKeys(from: newState.data.fieldIds, fields: newState.data.fields)

                subscriber(.success(newState))
            } catch let error {
                subscriber(.error(error))
            }
            return Disposables.create()
        }
    }

    private func updateDateFieldIfNeeded(in state: inout State) {
        guard var field = state.data.fields.values.first(where: { $0.baseField == FieldKeys.date }) else { return }

        let date: Date?

        // TODO: - check for current localization
        switch field.value.lowercased() {
        case "tomorrow":
            date = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case "today":
            date = Date()
        case "yesterday":
            date = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        default:
            date = nil
        }

        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"

            field.value = formatter.string(from: date)
            state.data.fields[field.key] = field
        }
    }

    private func createItem(with libraryId: LibraryIdentifier, collectionKey: String?, data: ItemDetailState.Data) throws -> RItem {
        let request = CreateItemDbRequest(libraryId: libraryId,
                                          collectionKey: collectionKey,
                                          data: data,
                                          schemaController: self.schemaController)
        return try self.dbStorage.createCoordinator().perform(request: request)
    }

    private func updateItem(key: String, libraryId: LibraryIdentifier, data: ItemDetailState.Data, snapshot: ItemDetailState.Data) throws {
        let request = StoreItemDetailChangesDbRequest(libraryId: libraryId,
                                                      itemKey: key,
                                                      data: data,
                                                      snapshot: snapshot,
                                                      schemaController: self.schemaController)
        try self.dbStorage.createCoordinator().perform(request: request)
    }
}

class ItemDetailStore: ObservableObject {
    enum Error: Swift.Error, Equatable, Identifiable, Hashable {
        case typeNotSupported, libraryNotAssigned,
             contentTypeUnknown, userMissing, downloadError, unknown,
             cantStoreChanges
        case fileNotCopied(Int)
        case droppedFields([String])

        var id: Int {
            return self.hashValue
        }
    }

    struct State {
        enum DetailType {
            case creation(libraryId: LibraryIdentifier, collectionKey: String?, filesEditable: Bool)
            case duplication(RItem, collectionKey: String?)
            case preview(RItem)

            var isCreation: Bool {
                switch self {
                case .preview:
                    return false
                case .creation, .duplication:
                    return true
                }
            }
        }

        struct Field: Identifiable, Equatable, Hashable {
            let key: String
            let baseField: String?
            var name: String
            var value: String
            let isTitle: Bool

            var id: String { return self.key }

            func hash(into hasher: inout Hasher) {
                hasher.combine(self.key)
                hasher.combine(self.value)
            }
        }

        struct Note: Identifiable, Equatable {
            let key: String
            var title: String
            var text: String

            var id: String { return self.key }

            init(key: String, text: String) {
                self.key = key
                self.title = text.strippedHtml ?? text
                self.text = text
            }

            init?(item: RItem) {
                guard item.rawType == ItemTypes.note else {
                    DDLogError("Trying to create Note from RItem which is not a note!")
                    return nil
                }

                self.key = item.key
                self.title = item.displayTitle
                self.text = item.fields.filter(.key(FieldKeys.note)).first?.value ?? ""
            }
        }

        struct Creator: Identifiable, Equatable, Hashable {
            enum NamePresentation: Equatable {
                case separate, full

                mutating func toggle() {
                    self = self == .full ? .separate : .full
                }
            }

            var type: String
            var primary: Bool
            var localizedType: String
            var fullName: String
            var firstName: String
            var lastName: String
            var namePresentation: NamePresentation {
                willSet {
                    self.change(namePresentation: newValue)
                }
            }

            var name: String {
                if !self.fullName.isEmpty {
                    return self.fullName
                }

                guard !self.firstName.isEmpty || !self.lastName.isEmpty else { return "" }

                var name = self.lastName
                if !self.lastName.isEmpty {
                    name += ", "
                }
                return name + self.firstName
            }

            var isEmpty: Bool {
                return self.fullName.isEmpty && self.firstName.isEmpty && self.lastName.isEmpty
            }

            let id: UUID

            init(firstName: String, lastName: String, fullName: String, type: String, primary: Bool, localizedType: String) {
                self.id = UUID()
                self.type = type
                self.primary = primary
                self.localizedType = localizedType
                self.fullName = fullName
                self.firstName = firstName
                self.lastName = lastName
                self.namePresentation = fullName.isEmpty ? .separate : .full
            }

            init(type: String, primary: Bool, localizedType: String) {
                self.id = UUID()
                self.type = type
                self.primary = primary
                self.localizedType = localizedType
                self.fullName = ""
                self.firstName = ""
                self.lastName = ""
                self.namePresentation = .full
            }

            mutating func change(namePresentation: NamePresentation) {
                guard namePresentation != self.namePresentation else { return }

                switch namePresentation {
                case .full:
                    self.fullName = self.firstName + (self.firstName.isEmpty ? "" : " ") + self.lastName
                    self.firstName = ""
                    self.lastName = ""
                case .separate:
                    if self.fullName.isEmpty {
                        self.firstName = ""
                        self.lastName = ""
                        return
                    }

                    if !self.fullName.contains(" ") {
                        self.lastName = self.fullName
                        self.firstName = ""
                        return
                    }

                    let components = self.fullName.components(separatedBy: " ")
                    self.firstName = components.dropLast().joined(separator: " ")
                    self.lastName = components.last ?? ""
                }
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(self.type)
                hasher.combine(self.primary)
                hasher.combine(self.fullName)
                hasher.combine(self.firstName)
                hasher.combine(self.lastName)
            }
        }

        struct Data: Equatable {
            var title: String
            var type: String
            var localizedType: String
            var creators: [UUID: Creator]
            var creatorIds: [UUID]
            var fields: [String: Field]
            var fieldIds: [String]
            var abstract: String?
            var notes: [Note]
            var attachments: [Attachment]
            var tags: [Tag]

            var dateModified: Date
            let dateAdded: Date

            var maxFieldTitleWidth: CGFloat = 0
            var maxNonemptyFieldTitleWidth: CGFloat = 0

            func databaseFields(schemaController: SchemaController) -> [Field] {
                var allFields = Array(self.fields.values)

                if let titleKey = schemaController.titleKey(for: self.type) {
                    allFields.append(State.Field(key: titleKey,
                                                 baseField: (titleKey != FieldKeys.title ? FieldKeys.title : nil),
                                                 name: "",
                                                 value: self.title,
                                                 isTitle: true))
                }

                if let abstract = self.abstract {
                    allFields.append(State.Field(key: FieldKeys.abstract,
                                                 baseField: nil,
                                                 name: "",
                                                 value: abstract,
                                                 isTitle: false))
                }


                return allFields
            }

            mutating func recalculateMaxTitleWidth() {
                var maxTitle = ""
                var maxNonEmptyTitle = ""

                self.fields.values.forEach { field in
                    if field.name.count > maxTitle.count {
                        maxTitle = field.name
                    }

                    if !field.value.isEmpty && field.name.count > maxNonEmptyTitle.count {
                        maxNonEmptyTitle = field.name
                    }
                }

                // TODO: - localize
                let extraFields = ["Item Type", "Date Modified", "Date Added", "Abstract"] + self.creators.values.map({ $0.localizedType })
                extraFields.forEach { name in
                    if name.count > maxTitle.count {
                        maxTitle = name
                    }
                    if name.count > maxNonEmptyTitle.count {
                        maxNonEmptyTitle = name
                    }
                }

                self.maxFieldTitleWidth = ceil(maxTitle.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]).width)
                self.maxNonemptyFieldTitleWidth = ceil(maxNonEmptyTitle.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]).width)
            }
        }

        let libraryId: LibraryIdentifier
        let userId: Int
        let metadataEditable: Bool
        let filesEditable: Bool

        var isEditing: Bool
        var type: DetailType
        var data: Data
        var snapshot: Data?
        var promptSnapshot: Data?
        var downloadProgress: [String: Double]
        var downloadError: [String: ItemDetailStore.Error]
        var error: Error?
        var presentedNote: Note
        var metadataTitleMaxWidth: CGFloat

        init(type: DetailType, userId: Int, data: Data, error: Error? = nil) {
            self.userId = userId
            self.type = type
            self.data = data
            self.downloadProgress = [:]
            self.downloadError = [:]
            self.metadataTitleMaxWidth = 0
            self.error = error
            self.presentedNote = Note(key: KeyGenerator.newKey, text: "")

            switch type {
            case .preview(let item), .duplication(let item, _):
                self.isEditing = false
                self.libraryId = item.libraryObject?.identifier ?? .custom(.myLibrary)
                self.snapshot = nil
                // Item has either grouop assigned with canEditMetadata or it's a custom library which is always editable
                self.metadataEditable = item.group?.canEditMetadata ?? true
                // Item has either grouop assigned with canEditFiles or it's a custom library which is always editable
                self.filesEditable = item.group?.canEditFiles ?? true
                // Filter fieldIds to show only non-empty values
                self.data.fieldIds = ItemDetailStore.filteredFieldKeys(from: self.data.fieldIds, fields: self.data.fields)
            case .creation(let libraryId, _, let filesEditable):
                self.isEditing = true
                self.libraryId = libraryId
                self.snapshot = data
                // Since we're in creation mode editing must have beeen enabled
                self.metadataEditable = true
                self.filesEditable = filesEditable
            }
        }

        init(type: DetailType, userId: Int, error: Error) {
            self.init(type: type,
                      userId: userId,
                      data: Data(title: "", type: "", localizedType: "",
                                 creators: [:], creatorIds: [],
                                 fields: [:], fieldIds: [],
                                 abstract: nil, notes: [],
                                 attachments: [], tags: [],
                                 dateModified: Date(), dateAdded: Date()),
                      error: error)
        }
    }

    private let apiClient: ApiClient
    private let fileStorage: FileStorage
    private let dbStorage: DbStorage
    private let schemaController: SchemaController
    private let disposeBag: DisposeBag

    @Published var state: State

    init(type: State.DetailType, userId: Int,
         apiClient: ApiClient, fileStorage: FileStorage,
         dbStorage: DbStorage, schemaController: SchemaController) {
        self.apiClient = apiClient
        self.fileStorage = fileStorage
        self.dbStorage = dbStorage
        self.schemaController = schemaController
        self.disposeBag = DisposeBag()

        do {
            var data = try ItemDetailStore.createData(from: type,
                                                      schemaController: schemaController,
                                                      fileStorage: fileStorage)
            data.recalculateMaxTitleWidth()
            self.state = State(type: type, userId: userId, data: data)
        } catch let error {
            self.state = State(type: type, userId: userId,
                               error: (error as? Error) ?? .typeNotSupported)
        }
    }

    private static func allFieldKeys(for itemType: String, schemaController: SchemaController) -> [String] {
        guard let fieldSchemas = schemaController.fields(for: itemType) else { return [] }
        var fieldKeys = fieldSchemas.map({ $0.field })
        // Remove title and abstract keys, those 2 are used separately in Data struct
        if let index = fieldKeys.firstIndex(of: FieldKeys.abstract) {
            fieldKeys.remove(at: index)
        }
        if let key = schemaController.titleKey(for: itemType), let index = fieldKeys.firstIndex(of: key) {
            fieldKeys.remove(at: index)
        }
        return fieldKeys
    }

    private static func filteredFieldKeys(from fieldKeys: [String], fields: [String: State.Field]) -> [String] {
        var newFieldKeys: [String] = []
        fieldKeys.forEach { key in
            if !(fields[key]?.value ?? "").isEmpty {
                newFieldKeys.append(key)
            }
        }
        return newFieldKeys
    }

    private static func fieldData(for itemType: String, schemaController: SchemaController,
                                  getExistingData: ((String, String?) -> (String?, String?))? = nil) throws -> ([String], [String: State.Field], Bool) {
        guard var fieldSchemas = schemaController.fields(for: itemType) else {
            throw Error.typeNotSupported
        }

        var fieldKeys = fieldSchemas.map({ $0.field })
        let abstractIndex = fieldKeys.firstIndex(of: FieldKeys.abstract)

        // Remove title and abstract keys, those 2 are used separately in Data struct
        if let index = abstractIndex {
            fieldKeys.remove(at: index)
            fieldSchemas.remove(at: index)
        }
        if let key = schemaController.titleKey(for: itemType), let index = fieldKeys.firstIndex(of: key) {
            fieldKeys.remove(at: index)
            fieldSchemas.remove(at: index)
        }

        var fields: [String: State.Field] = [:]
        for (offset, key) in fieldKeys.enumerated() {
            let baseField = fieldSchemas[offset].baseField
            let (existingName, existingValue) = (getExistingData?(key, baseField) ?? (nil, nil))

            let name = existingName ?? schemaController.localized(field: key) ?? ""
            let value = existingValue ?? ""

            fields[key] = State.Field(key: key,
                                      baseField: baseField,
                                      name: name,
                                      value: value,
                                      isTitle: false)
        }

        return (fieldKeys, fields, (abstractIndex != nil))
    }

    static func createData(from type: State.DetailType,
                           schemaController: SchemaController,
                           fileStorage: FileStorage) throws -> State.Data {
        switch type {
        case .creation:
            guard let itemType = schemaController.itemTypes.sorted().first,
                  let localizedType = schemaController.localized(itemType: itemType) else {
                throw Error.typeNotSupported
            }
            let (fieldIds, fields, hasAbstract) = try ItemDetailStore.fieldData(for: itemType, schemaController: schemaController)
            let date = Date()

            return State.Data(title: "",
                              type: itemType,
                              localizedType: localizedType,
                              creators: [:],
                              creatorIds: [],
                              fields: fields,
                              fieldIds: fieldIds,
                              abstract: (hasAbstract ? "" : nil),
                              notes: [],
                              attachments: [],
                              tags: [],
                              dateModified: date,
                              dateAdded: date)

        case .preview(let item), .duplication(let item, _):
            guard let localizedType = schemaController.localized(itemType: item.rawType) else {
                throw Error.typeNotSupported
            }

            var abstract: String?
            var values: [String: String] = [:]

            item.fields.forEach { field in
                switch field.key {
                case FieldKeys.abstract:
                    abstract = field.value
                default:
                    values[field.key] = field.value
                }
            }

            let (fieldIds, fields, _) = try ItemDetailStore.fieldData(for: item.rawType,
                                                                      schemaController: schemaController,
                                                                      getExistingData: { key, _ -> (String?, String?) in
                return (nil, values[key])
            })

            var creatorIds: [UUID] = []
            var creators: [UUID: State.Creator] = [:]
            for creator in item.creators.sorted(byKeyPath: "orderId") {
                guard let localizedType = schemaController.localized(creator: creator.rawType) else { continue }

                let creator = State.Creator(firstName: creator.firstName,
                                            lastName: creator.lastName,
                                            fullName: creator.name,
                                            type: creator.rawType,
                                            primary: schemaController.creatorIsPrimary(creator.rawType, itemType: item.rawType),
                                            localizedType: localizedType)
                creatorIds.append(creator.id)
                creators[creator.id] = creator
            }

            let notes = item.children.filter(.items(type: ItemTypes.note, notSyncState: .dirty, trash: false))
                                     .sorted(byKeyPath: "displayTitle")
                                     .compactMap(State.Note.init)
            let attachments: [Attachment]
            if item.rawType == ItemTypes.attachment {
                let attachment = self.attachmentType(for: item, fileStorage: fileStorage).flatMap({ Attachment(item: item, type: $0) })
                attachments = attachment.flatMap { [$0] } ?? []
            } else {
                let mappedAttachments = item.children.filter(.items(type: ItemTypes.attachment, notSyncState: .dirty, trash: false))
                                                     .sorted(byKeyPath: "displayTitle")
                                                     .compactMap({ item -> Attachment? in
                                                         return attachmentType(for: item, fileStorage: fileStorage)
                                                                            .flatMap({ Attachment(item: item, type: $0) })
                                                     })
                attachments = Array(mappedAttachments)
            }

            let tags = item.tags.sorted(byKeyPath: "name").map(Tag.init)

            return State.Data(title: item.baseTitle,
                              type: item.rawType,
                              localizedType: localizedType,
                              creators: creators,
                              creatorIds: creatorIds,
                              fields: fields,
                              fieldIds: fieldIds,
                              abstract: abstract,
                              notes: Array(notes),
                              attachments: attachments,
                              tags: Array(tags),
                              dateModified: item.dateModified,
                              dateAdded: item.dateAdded)
        }
    }

    private static func attachmentType(for item: RItem, fileStorage: FileStorage) -> Attachment.ContentType? {
        let contentType = item.fields.filter(.key(FieldKeys.contentType)).first?.value ?? ""
        if !contentType.isEmpty { // File attachment
            if let ext = contentType.extensionFromMimeType,
               let libraryId = item.libraryObject?.identifier {
                let filename = item.fields.filter(.key(FieldKeys.filename)).first?.value ?? (item.displayTitle + "." + ext)
                let file = Files.objectFile(for: .item, libraryId: libraryId, key: item.key, ext: ext)
                let isLocal = fileStorage.has(file)
                return .file(file: file, filename: filename, isLocal: isLocal)
            } else {
                DDLogError("Attachment: mimeType/extension unknown (\(contentType)) for item (\(item.key))")
                return nil
            }
        } else { // Some other attachment (url, etc.)
            if let urlString = item.fields.filter("key = %@", "url").first?.value,
               let url = URL(string: urlString) {
                return .url(url)
            } else {
                DDLogError("Attachment: unknown attachment, fields: \(item.fields.map({ $0.key }))")
                return nil
            }
        }
    }

    func acceptPromptSnapshot() {
        guard let snapshot = self.state.promptSnapshot else { return }
        self.state.promptSnapshot = nil
        self.state.data = snapshot
    }

    func cancelPromptSnapshot() {
        self.state.promptSnapshot = nil
    }

    func changeType(to newType: String) {
        do {
            let data = try self.data(for: newType, from: self.state.data)
            try self.set(data: data)
        } catch let error {
            self.state.error = (error as? Error) ?? .typeNotSupported
        }
    }

    private func set(data: State.Data) throws {
        let newFieldNames = Set(data.fields.values.map({ $0.name }))
        let oldFieldNames = Set(self.state.data.fields.values.filter({ !$0.value.isEmpty }).map({ $0.name }))
        let droppedNames = oldFieldNames.subtracting(newFieldNames).sorted()

        guard droppedNames.isEmpty else {
            self.state.promptSnapshot = data
            throw ItemDetailStore.Error.droppedFields(droppedNames)
        }

        self.state.data = data
    }

    private func data(for type: String, from originalData: State.Data) throws -> State.Data {
        guard let localizedType = self.schemaController.localized(itemType: type) else {
            throw Error.typeNotSupported
        }

        let (fieldIds, fields, hasAbstract) = try ItemDetailStore.fieldData(for: type,
                                                                            schemaController: self.schemaController,
                                                                            getExistingData: { key, baseField -> (String?, String?) in
            if let field = originalData.fields[key] {
                return (field.name, field.value)
            } else if let base = baseField, let field = originalData.fields.values.first(where: { $0.baseField == base }) {
                // We don't return existing name, because fields that are matching just by baseField will most likely have different names
                return (nil, field.value)
            }
            return (nil, nil)
        })

        var data = originalData
        data.type = type
        data.localizedType = localizedType
        data.fields = fields
        data.fieldIds = fieldIds
        data.abstract = hasAbstract ? (originalData.abstract ?? "") : nil
        data.creators = try self.creators(for: type, from: originalData.creators)
        data.creatorIds = originalData.creatorIds
        data.recalculateMaxTitleWidth()

        return data
    }

    private func creators(for type: String, from originalData: [UUID: State.Creator]) throws -> [UUID: State.Creator] {
        guard let schemas = self.schemaController.creators(for: type),
              let primary = schemas.first(where: { $0.primary }) else { throw Error.typeNotSupported }

        var creators = originalData
        for (key, originalCreator) in originalData {
            guard !schemas.contains(where: { $0.creatorType == originalCreator.type }) else { continue }

            var creator = originalCreator

            if originalCreator.primary {
                creator.type = primary.creatorType
            } else {
                creator.type = "contributor"
            }
            creator.localizedType = self.schemaController.localized(creator: creator.type) ?? ""

            creators[key] = creator
        }

        return creators
    }

    func addAttachments(from urls: [URL]) {
        var errors = 0

        for url in urls {
            let originalFile = Files.file(from: url)
            let key = KeyGenerator.newKey
            let file = Files.objectFile(for: .item,
                                        libraryId: self.state.libraryId,
                                        key: key,
                                        ext: originalFile.ext)
            let attachment = Attachment(key: key,
                                        title: originalFile.name,
                                        type: .file(file: file, filename: originalFile.name, isLocal: true),
                                        libraryId: self.state.libraryId)

            do {
                try self.fileStorage.move(from: originalFile, to: file)

                let index = self.state.data.attachments.index(of: attachment, sortedBy: { $0.title.caseInsensitiveCompare($1.title) == .orderedAscending })
                self.state.data.attachments.insert(attachment, at: index)
            } catch let error {
                DDLogError("ItemDertailStore: can't copy attachment - \(error)")
                errors += 1
            }
        }

        if errors > 0 {
            self.state.error = .fileNotCopied(errors)
        }
    }

    func addCreator() {
        // Check whether there already is an empty/new creator, add only if there is none
        guard self.state.data.creators.values.first(where: { $0.isEmpty }) == nil,
              let schema = self.schemaController.creators(for: self.state.data.type)?.first(where: { $0.primary }),
              let localized = self.schemaController.localized(creator: schema.creatorType) else { return }

        let creator = State.Creator(type: schema.creatorType, primary: schema.primary, localizedType: localized)
        self.state.data.creatorIds.append(creator.id)
        self.state.data.creators[creator.id] = creator
    }

    func deleteCreators(at offsets: IndexSet) {
        let keys = offsets.map({ self.state.data.creatorIds[$0] })
        self.state.data.creatorIds.remove(atOffsets: offsets)
        keys.forEach({ self.state.data.creators[$0] = nil })
    }

    func moveCreators(from offsets: IndexSet, to index: Int) {
        self.state.data.creatorIds.move(fromOffsets: offsets, toOffset: index)
    }

    func openNote(_ note: State.Note) {
        self.state.presentedNote = note
    }

    func addNote() {
        self.state.presentedNote = State.Note(key: KeyGenerator.newKey, text: "")
    }

    func deleteNotes(at offsets: IndexSet) {
        self.state.data.notes.remove(atOffsets: offsets)
    }

    func saveNote(text: String) {
        var state = self.state

        var note = state.presentedNote
        note.text = text
        note.title = text.strippedHtml ?? ""

        if let index = self.state.data.notes.firstIndex(where: { $0.key == note.key }) {
            self.state.data.notes[index] = note
        } else {
            self.state.data.notes.append(note)
        }
        if !state.isEditing {
            // Note was edited outside of editing mode, so it needs to be saved immediately
            self.saveNoteChanges(note)
        }
    }

    private func saveNoteChanges(_ note: State.Note) {
//        do {
//            let request = StoreNoteDbRequest(note: note, libraryId: self.state.libraryId)
//            try self.dbStorage.createCoordinator().perform(request: request)
//        } catch let error {
//            DDLogError("ItemDetailStore: can't store note - \(error)")
//            self.state.error = .cantStoreChanges
//        }
    }

    func setTags(_ tags: [Tag]) {
        self.state.data.tags = tags
    }

    func deleteTags(at offsets: IndexSet) {
        self.state.data.tags.remove(atOffsets: offsets)
    }

    func deleteAttachments(at offsets: IndexSet) {
        self.state.data.attachments.remove(atOffsets: offsets)
    }

    func openAttachment(_ attachment: Attachment) {
        switch attachment.type {
        case .url(let url):
            NotificationCenter.default.post(name: .presentWeb, object: url)
        case .file(let file, _, let isCached):
            if isCached {
                self.openFile(file)
            } else {
                self.cacheFile(file, key: attachment.key)
            }
        }
    }

    private func cacheFile(_ file: File, key: String) {
        let request = FileRequest(data: .internal(self.state.libraryId, self.state.userId, key), destination: file)
        self.apiClient.download(request: request)
                      .flatMap { request in
                          return request.rx.progress()
                      }
                      .observeOn(MainScheduler.instance)
                      .subscribe(onNext: { [weak self] progress in
                          let progress = progress.totalBytes == 0 ? 0 : Double(progress.bytesWritten) / Double(progress.totalBytes)
                          self?.state.downloadProgress[key] = progress
                      }, onError: { [weak self] error in
                          self?.finishCachingFile(for: key, result: .failure(error))
                      }, onCompleted: { [weak self] in
                          self?.finishCachingFile(for: key, result: .success(()))
                      })
                      .disposed(by: self.disposeBag)
    }

    private func finishCachingFile(for key: String, result: Result<(), Swift.Error>) {
        switch result {
        case .failure(let error):
            DDLogError("ItemDetailStore: show attachment - can't download file - \(error)")
            self.state.downloadError[key] = .downloadError

        case .success:
            self.state.downloadProgress[key] = nil
            if let (index, attachment) = self.state.data.attachments.enumerated().first(where: { $1.key == key }) {
                self.state.data.attachments[index] = attachment.changed(isLocal: true)
                self.openAttachment(attachment)
            }
        }
    }

    private func openFile(_ file: File) {
        switch file.ext {
        case "pdf":
            #if PDFENABLED
            NotificationCenter.default.post(name: .presentPdf, object: file.createUrl())
            #endif
        default:
            NotificationCenter.default.post(name: .presentUnknownAttachment, object: file.createUrl())
        }
    }

    // MARK: - Editing

    func startEditing() {
        var state = self.state
        state.snapshot = state.data
        state.data.fieldIds = ItemDetailStore.allFieldKeys(for: state.data.type, schemaController: self.schemaController)
        state.isEditing = true
        self.state = state
    }

    func cancelChanges() {
        guard let snapshot = self.state.snapshot else { return }
        var state = self.state
        state.data = snapshot
        state.snapshot = nil
        state.isEditing = false
        self.state = state
    }

    func saveChanges() {
        if self.state.snapshot != self.state.data {
            self._saveChanges()
        }
    }

    private func _saveChanges() {
        // TODO: - move to background thread if possible
        // SWIFTUI BUG: - sync store with environment .editMode so that we can switch edit mode when background task finished

        // TODO: - add loading indicator for saving

        self.save(state: self.state)
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { [weak self] state in
                self?.state = state
            }, onError: { [weak self] error in
                DDLogError("ItemDetailStore: can't store changes - \(error)")
                self?.state.error = (error as? Error) ?? .cantStoreChanges
            })
            .disposed(by: self.disposeBag)
    }

    private func save(state: State) -> Single<State> {
        return Single.create { subscriber -> Disposable in
            do {
                try self.fileStorage.copyAttachmentFilesIfNeeded(for: state.data.attachments)

                var newState = state
                var newType: State.DetailType?

                self.updateDateFieldIfNeeded(in: &newState)
                newState.data.dateModified = Date()

                switch self.state.type {
                case .preview(let item):
                    if let snapshot = state.snapshot {
                        try self.updateItem(key: item.key, libraryId: state.libraryId, data: state.data, snapshot: snapshot)
                    }

                case .creation(_, let collectionKey, _), .duplication(_, let collectionKey): break
//                    let item = try self.createItem(with: state.libraryId, collectionKey: collectionKey, data: state.data)
//                    newType = .preview(item)
                }

                newState.snapshot = nil
                if let type = newType {
                    newState.type = type
                }
                newState.isEditing = false
                newState.data.fieldIds = ItemDetailStore.filteredFieldKeys(from: newState.data.fieldIds, fields: newState.data.fields)

                subscriber(.success(newState))
            } catch let error {
                subscriber(.error(error))
            }
            return Disposables.create()
        }
    }

    private func updateDateFieldIfNeeded(in state: inout State) {
        guard var field = state.data.fields.values.first(where: { $0.baseField == FieldKeys.date }) else { return }

        let date: Date?

        // TODO: - check for current localization
        switch field.value.lowercased() {
        case "tomorrow":
            date = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case "today":
            date = Date()
        case "yesterday":
            date = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        default:
            date = nil
        }

        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"

            field.value = formatter.string(from: date)
            state.data.fields[field.key] = field
        }
    }

//    private func createItem(with libraryId: LibraryIdentifier, collectionKey: String?, data: State.Data) throws -> RItem {
//        let request = CreateItemDbRequest(libraryId: libraryId,
//                                          collectionKey: collectionKey,
//                                          data: data,
//                                          schemaController: self.schemaController)
//        return try self.dbStorage.createCoordinator().perform(request: request)
//    }

    private func updateItem(key: String, libraryId: LibraryIdentifier, data: State.Data, snapshot: State.Data) throws {
//        let request = StoreItemDetailChangesDbRequest(libraryId: libraryId,
//                                                      itemKey: key,
//                                                      data: data,
//                                                      snapshot: snapshot,
//                                                      schemaController: self.schemaController)
//        try self.dbStorage.createCoordinator().perform(request: request)
    }
}

extension FileStorage {
    /// Copy attachments from file picker url (external app sandboxes) to our internal url (our app sandbox)
    /// - parameter attachments: Attachments which will be copied if needed
    func copyAttachmentFilesIfNeeded(for attachments: [Attachment]) throws {
        for attachment in attachments {
            switch attachment.type {
            case .url: continue
            case .file(let originalFile, _, _):
                let newFile = Files.objectFile(for: .item, libraryId: attachment.libraryId,
                                               key: attachment.key, ext: originalFile.ext)
                // Make sure that the file was not already moved to our internal location before
                guard originalFile.createUrl() != newFile.createUrl() else { continue }

                try self.copy(from: originalFile, to: newFile)
            }
        }
    }
}
