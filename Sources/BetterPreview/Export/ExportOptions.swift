import BPCore
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct ExportFailure: LocalizedError {
    var errorDescription: String?
}

/// What File > Export offers for a PDF: the format, its options, and the PDF
/// extras (smaller file, passwords and permissions).
struct PDFExportOptions {
    init(format: Format = .pdf, allowPrinting: Bool = true) {
        self.format = format
        self.allowPrinting = allowPrinting
    }

    enum Format: String, CaseIterable {
        case pdf, jpeg, png, tiff, heic

        var title: String {
            switch self {
            case .pdf: "PDF"
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .tiff: "TIFF"
            case .heic: "HEIC"
            }
        }

        var type: UTType {
            switch self {
            case .pdf: .pdf
            case .jpeg: .jpeg
            case .png: .png
            case .tiff: .tiff
            case .heic: .heic
            }
        }

        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var isImage: Bool { self != .pdf }
        var supportsQuality: Bool { self == .jpeg || self == .heic }

        init?(extension ext: String) {
            switch ext.lowercased() {
            case "pdf": self = .pdf
            case "jpg", "jpeg": self = .jpeg
            case "png": self = .png
            case "tif", "tiff": self = .tiff
            case "heic", "heif": self = .heic
            default: return nil
            }
        }
    }

    var format: Format = .pdf
    /// Images: only the page being viewed instead of one file per page.
    var currentPageOnly = false
    var dpi = 144.0
    /// 0...1, JPEG and HEIC.
    var quality = 0.85
    /// PDF: downsample images to screen resolution and store them as JPEG
    /// (the "Reduce File Size" Quartz filter).
    var reduceSize = false
    /// PDF: both nil or empty means no encryption.
    var openPassword: String?
    var ownerPassword: String?
    var allowPrinting = true
    var allowCopying = true
    var allowEditing = true
    /// PDF: the source is encrypted and the copy must not be.
    var stripEncryption = false

    var wantsEncryption: Bool { !(openPassword ?? "").isEmpty || !(ownerPassword ?? "").isEmpty }
    var restrictsPermissions: Bool { !(allowPrinting && allowCopying && allowEditing) }

    /// Highest resolution accepted: a page is rendered into one bitmap.
    static let maxDPI = 1200.0

    /// PDFAccessPermissions bits (PDFDocument.h); the enum is not an OptionSet.
    var permissions: UInt {
        var bits: UInt = 0
        if allowPrinting { bits |= 1 << 0 | 1 << 1 }
        if allowCopying { bits |= 1 << 4 | 1 << 5 }
        if allowEditing { bits |= 1 << 2 | 1 << 3 | 1 << 6 | 1 << 7 }
        // Form entry and accessibility stay available, like Preview.
        return bits | 1 << 7 | 1 << 5
    }

    /// Checks combinations that cannot work.
    func validate() throws {
        guard dpi >= 10, dpi <= Self.maxDPI else {
            throw ExportFailure(errorDescription: "Resolution must be between 10 and \(Int(Self.maxDPI)) dpi")
        }
        if format == .pdf, restrictsPermissions, (ownerPassword ?? "").isEmpty {
            throw ExportFailure(errorDescription: "Set an owner password to restrict printing, copying or editing")
        }
    }
}

/// `export [path] [options…]` parsed from the argument string.
struct ExportRequest {
    var path: String?
    var options = PDFExportOptions()
    /// Typed path may replace an existing file (`!` suffix on the command).
    var force = false
    /// Scripted export of an encrypted document without its encryption.
    var decrypt = false
    /// The format was named by a token rather than by the path's extension.
    var formatGiven = false

    static let usage = "export [path] [dpi] [reduce] [pw=…] [owner=…] [noprint] [nocopy] [noedit] [decrypt] [current] [quality=N] [force]"

    static func parse(_ argument: String?) throws -> ExportRequest {
        var request = ExportRequest()
        var formatFromPath = true
        for word in CommandParser.splitArgumentWords(argument ?? "") {
            let token = word.text
            let lower = token.lowercased()
            if word.quoted {
                // Quoted: always the file name ("2024" or "png" included).
                guard request.path == nil else {
                    throw ExportFailure(errorDescription: "export: unexpected '\(token)' (\(usage))")
                }
                request.path = token
            } else if let format = PDFExportOptions.Format(rawValue: lower), token.first?.isLetter == true,
               !token.contains(".") {
                request.options.format = format
                request.formatGiven = true
                formatFromPath = false
            } else if let dpi = Double(token) {
                request.options.dpi = dpi
            } else if lower == "reduce" {
                request.options.reduceSize = true
            } else if lower == "current" {
                request.options.currentPageOnly = true
            } else if lower == "noprint" {
                request.options.allowPrinting = false
            } else if lower == "nocopy" {
                request.options.allowCopying = false
            } else if lower == "noedit" {
                request.options.allowEditing = false
            } else if lower == "decrypt" {
                request.decrypt = true
                request.options.stripEncryption = true
            } else if lower == "force" || lower == "!" {
                request.force = true
            } else if lower.hasPrefix("pw="), token.count > 3 {
                request.options.openPassword = String(token.dropFirst(3))
            } else if lower.hasPrefix("owner="), token.count > 6 {
                request.options.ownerPassword = String(token.dropFirst(6))
            } else if lower.hasPrefix("quality="), let q = Double(token.dropFirst(8)), (1...100).contains(q) {
                request.options.quality = q / 100
            } else if request.path == nil {
                request.path = token
            } else {
                throw ExportFailure(errorDescription: "export: unexpected '\(token)' (\(usage))")
            }
        }
        if let path = request.path {
            let ext = (path as NSString).pathExtension
            let pathFormat = PDFExportOptions.Format(extension: ext)
            if formatFromPath, let pathFormat {
                request.options.format = pathFormat
            } else if formatFromPath {
                guard ext.isEmpty else {
                    throw ExportFailure(errorDescription: "export: unknown format .\(ext) (pdf, jpg, png, tiff, heic)")
                }
                // "export out": no extension and no format: PDF.
                request.path = path + "." + request.options.format.fileExtension
            } else if let pathFormat, pathFormat != request.options.format {
                // "export out.pdf png" would write PNG data into a .pdf.
                throw ExportFailure(errorDescription: "export: \((path as NSString).lastPathComponent) does not match "
                                    + "the format \(request.options.format.title)")
            } else if pathFormat == nil {
                // "export out png", "export notes.v2 png": add the format's extension.
                request.path = path + "." + request.options.format.fileExtension
            }
        }
        return request
    }

    /// Splits on spaces; double quotes keep a path with spaces together.
    static func tokenize(_ text: String) -> [String] { CommandParser.splitArguments(text) }
}
