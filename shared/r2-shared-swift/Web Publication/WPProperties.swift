//
//  WPProperties.swift
//  r2-shared-swift
//
//  Created by Mickaël Menu on 09.03.19.
//
//  Copyright 2019 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import Foundation


/// Link Properties
/// https://readium.org/webpub-manifest/schema/properties.schema.json
public struct WPProperties: Equatable {

    /// Suggested orientation for the device when displaying the linked resource.
    public var orientation: WPOrientation?

    /// Indicates how the linked resource should be displayed in a reading environment that displays synthetic spreads.
    public var page: WPPage?

    
    // MARK: - EPUB Extension
    // https://readium.org/webpub-manifest/schema/extensions/epub/properties.schema.json

    /// Identifies content contained in the linked resource, that cannot be strictly identified using a media type.
    public var contains: [String]
    
    /// Hints how the layout of the resource should be presented.
    public var layout: WPLayout?

    /// Location of a media-overlay for the resource referenced in the Link Object.
    public var mediaOverlay: String?
    
    /// Suggested method for handling overflow while displaying the linked resource.
    public var overflow: WPOverflow?
    
    /// Indicates the condition to be met for the linked resource to be rendered within a synthetic spread.
    public var spread: WPSpread?
    
    /// Indicates that a resource is encrypted/obfuscated and provides relevant information for decryption.
    public var encrypted: WPEncrypted?
    
    
    // FIXME: OPDS: https://drafts.opds.io/schema/properties.schema.json

    public init(orientation: WPOrientation? = nil, page: WPPage? = nil, contains: [String] = [], layout: WPLayout? = nil, mediaOverlay: String? = nil, overflow: WPOverflow? = nil, spread: WPSpread? = nil, encrypted: WPEncrypted? = nil) {
        self.orientation = orientation
        self.page = page
        self.contains = contains
        self.layout = layout
        self.mediaOverlay = mediaOverlay
        self.overflow = overflow
        self.spread = spread
        self.encrypted = encrypted
    }
    
    public init?(json: Any?) throws {
        if json == nil {
            return nil
        }
        guard let json = json as? [String: Any] else {
            throw WPParsingError.properties
        }
        
        self.orientation = parseRaw(json["orientation"])
        self.page = parseRaw(json["page"])
        self.contains = parseArray(json["contains"])
        self.layout = parseRaw(json["layout"])
        self.mediaOverlay = json["media-overlay"] as? String
        self.overflow = parseRaw(json["overflow"])
        self.spread = parseRaw(json["spread"])
        self.encrypted = try WPEncrypted(json: json["encrypted"])
    }
    
    public var json: [String: Any]? {
        let json = makeJSON([
            "orientation": encodeRawIfNotNil(orientation),
            "page": encodeRawIfNotNil(page),
            "contains": encodeIfNotEmpty(contains),
            "layout": encodeRawIfNotNil(layout),
            "media-overlay": encodeIfNotNil(mediaOverlay),
            "overflow": encodeRawIfNotNil(overflow),
            "spread": encodeRawIfNotNil(spread),
            "encrypted": encodeIfNotNil(encrypted?.json),
        ])
        // Nil if empty to not include the properties in the parent structure.
        return json.isEmpty ? nil : json
    }

}
