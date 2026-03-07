//
//  Extensions.swift
//  StikDebug
//
//  Created by s s on 2025/7/9.
//
import UIKit
import UniformTypeIdentifiers

extension FileManager {
    func filePath(atPath path: String, withLength length: Int) -> String? {
        guard let file = try? contentsOfDirectory(atPath: path).first(where: { $0.count == length }) else { return nil }
        return "\(path)/\(file)"
    }
}

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

extension Notification.Name {
    static let pairingFileImported = Notification.Name("PairingFileImported")
}

