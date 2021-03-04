//
//  RealmDbController.swift
//  Zotero
//
//  Created by Michal Rentka on 04/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift
import RealmSwift

enum RealmDbError: Error {
    case autocreateMissingPrimaryKey
}

final class RealmDbStorage {
    private let config: Realm.Configuration

    init(config: Realm.Configuration) {
        self.config = config
    }

    func clear() {
        guard let realmUrl = self.config.fileURL else { return }

        let realmUrls = [realmUrl,
                         realmUrl.appendingPathExtension("lock"),
                         realmUrl.appendingPathExtension("note"),
                         realmUrl.appendingPathExtension("management")]

        for url in realmUrls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error {
                DDLogError("RealmDbStorage: couldn't delete file at '\(url.absoluteString)' - \(error)")
            }
        }
    }
}

extension RealmDbStorage: DbStorage {
    func createCoordinator() throws -> DbCoordinator {
        return try RealmDbCoordinator(config: self.config)
    }
}

struct RealmDbCoordinator {
    private let realm: Realm

    init(config: Realm.Configuration) throws {
        self.realm = try Realm(configuration: config)
    }
}

extension RealmDbCoordinator: DbCoordinator {
    func perform(request: DbRequest) throws  {
        if !request.needsWrite {
            try request.process(in: self.realm)
            return
        }

        try self.realm.write {
            try request.process(in: self.realm)
        }
    }

    func perform<Request>(request: Request) throws -> Request.Response where Request : DbResponseRequest {
        if !request.needsWrite {
            return try request.process(in: self.realm)
        }

        return try self.realm.write {
            return try request.process(in: self.realm)
        }
    }

    /// Writes multiple requests in single write transaction.
    func perform(requests: [DbRequest]) throws {
        try self.realm.write {
            for request in requests {
                guard request.needsWrite else { continue }
                try request.process(in: self.realm)
            }
        }
    }
}

extension Realm {
    /// Tries to find a library object with LibraryIdentifier, if it doesn't exist it creates a new object
    /// - parameter key: Identifier for given library object
    /// - returns: Tuple, Bool indicates whether the object had to be created and LibraryObject is the existing/new object
    func autocreatedLibraryObject(forPrimaryKey key: LibraryIdentifier) throws -> (Bool, LibraryObject) {
        switch key {
        case .custom(let type):
            let (isNew, object) = try self.autocreatedObject(ofType: RCustomLibrary.self, forPrimaryKey: type.rawValue)
            return (isNew, .custom(object))

        case .group(let identifier):
            let (isNew, object) = try self.autocreatedObject(ofType: RGroup.self, forPrimaryKey: identifier)
            return (isNew, .group(object))
        }
    }

    /// Tries to find an object with primary key, if it doesn't exist it creates a new object
    /// - parameter type: Type of object to return
    /// - parameter key: Primary key of object
    /// - returns: Tuple, Bool indicates whether the object had to be created and Element is the existing/new object
    func autocreatedObject<Element: Object, KeyType>(ofType type: Element.Type,
                                                     forPrimaryKey key: KeyType) throws -> (Bool, Element) {
        if let existing = self.object(ofType: type, forPrimaryKey: key) {
            return (false, existing)
        }

        guard let primaryKey = type.primaryKey() else {
            throw RealmDbError.autocreateMissingPrimaryKey
        }

        let object = type.init()
        object.setValue(key, forKey: primaryKey)
        self.add(object)
        return (true, object)
    }
}
