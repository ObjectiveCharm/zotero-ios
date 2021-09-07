//
//  UserDefaults.swift
//  Zotero
//
//  Created by Michal Rentka on 18/11/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

final class Defaults {
    static let shared = Defaults()

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    // MARK: - Session

    @UserDefault(key: "username", defaultValue: "")
    var username: String

    @UserDefault(key: "userid", defaultValue: 0)
    var userId: Int

    // MARK: - Settings

    @UserDefault(key: "ShareExtensionIncludeTags", defaultValue: true)
    var shareExtensionIncludeTags: Bool

    @UserDefault(key: "ShareExtensionIncludeAttachment", defaultValue: true)
    var shareExtensionIncludeAttachment: Bool

    @UserDefault(key: "ShowSubcollectionItems", defaultValue: false, defaults: .standard)
    var showSubcollectionItems: Bool

    @UserDefault(key: "QuickCopyStyleId", defaultValue: "http://www.zotero.org/styles/chicago-note-bibliography", defaults: .standard)
    var quickCopyStyleId: String

    // Proper default value is set up in AppDelegate.setupExportDefaults().
    @UserDefault(key: "QuickCopyLocaleId", defaultValue: "en-US", defaults: .standard)
    var quickCopyLocaleId: String

    @UserDefault(key: "QuickCopyAsHtml", defaultValue: false, defaults: .standard)
    var quickCopyAsHtml: Bool

    // MARK: - Selection

    @CodableUserDefault(key: "SelectedRawLibraryKey", defaultValue: LibraryIdentifier.custom(.myLibrary), encoder: Defaults.jsonEncoder, decoder: Defaults.jsonDecoder)
    var selectedLibrary: LibraryIdentifier

    @CodableUserDefault(key: "SelectedRawCollectionKey", defaultValue: CollectionIdentifier.custom(.all), encoder: Defaults.jsonEncoder, decoder: Defaults.jsonDecoder)
    var selectedCollectionId: CollectionIdentifier

    // MARK: - Items Settings

    #if MAINAPP
    @CodableUserDefault(key: "RawItemsSortType", defaultValue: ItemsSortType.default, encoder: Defaults.jsonEncoder, decoder: Defaults.jsonDecoder, defaults: .standard)
    var itemsSortType: ItemsSortType
    #endif

    // MARK: - PDF Settings

    @UserDefault(key: "PdfReaderLineWidth", defaultValue: 2)
    var activeLineWidth: Float

    #if PDFENABLED && MAINAPP
    @UserDefault(key: "PDFReaderState.activeColor", defaultValue: AnnotationsConfig.defaultActiveColor)
    var activeColorHex: String

    @CodableUserDefault(key: "PDFReaderSettings", defaultValue: PDFSettingsState.default, encoder: Defaults.jsonEncoder, decoder: Defaults.jsonDecoder, defaults: .standard)
    var pdfSettings: PDFSettingsState
    #endif

    // MARK: - Citation / Bibliography Export

    @UserDefault(key: "exportStyleId", defaultValue: "http://www.zotero.org/styles/chicago-note-bibliography", defaults: .standard)
    var exportStyleId: String

    // Proper default value is set up in AppDelegate.setupExportDefaults().
    @UserDefault(key: "exportLocaleId", defaultValue: "en-US", defaults: .standard)
    var exportLocaleId: String

    #if MAINAPP
    @CodableUserDefault(key: "ExportOutputMethod", defaultValue: .copy, encoder: Defaults.jsonEncoder, decoder: Defaults.jsonDecoder)
    var exportOutputMethod: CitationBibliographyExportState.OutputMethod

    @CodableUserDefault(key: "ExportOutputMode", defaultValue: .bibliography, encoder: Defaults.jsonEncoder, decoder: Defaults.jsonDecoder)
    var exportOutputMode: CitationBibliographyExportState.OutputMode
    #endif

    // MARK: - Helpers

    @OptionalUserDefault(key: "LastLaunchBuildNumber", defaults: .standard)
    var lastBuildNumber: Int?

    @UserDefault(key: "AskForSyncPermission", defaultValue: false)
    var askForSyncPermission: Bool

    // MARK: - Actions

    func reset() {
        self.askForSyncPermission = false
        self.username = ""
        self.userId = 0
        self.shareExtensionIncludeTags = true
        self.shareExtensionIncludeAttachment = true
        self.selectedLibrary = .custom(.myLibrary)
        self.selectedCollectionId = .custom(.all)
    }
}
