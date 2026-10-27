import Foundation

/// File types the engine recognizes from magic bytes.
public enum DetectedFileType: String, Sendable, Hashable, Codable, CaseIterable {
    case machO, pe, elf, script, pdf, jpeg, png, unknown

    /// Mach-O, PE, ELF or a `#!` script.
    public var isExecutable: Bool {
        switch self {
        case .machO, .pe, .elf, .script: true
        default: false
        }
    }

    /// The ClamAV `.ndb` target type whose patterns apply in addition to
    /// target 0, or nil when only target 0 applies.
    public var clamTarget: Int? {
        switch self {
        case .pe: 1
        case .jpeg, .png: 5
        case .elf: 6
        case .script: 7
        case .machO: 9
        case .pdf: 10
        case .unknown: nil
        }
    }

    public var displayName: String {
        switch self {
        case .machO: "Mach-O executable"
        case .pe: "Windows PE executable"
        case .elf: "ELF executable"
        case .script: "Script"
        case .pdf: "PDF document"
        case .jpeg: "JPEG image"
        case .png: "PNG image"
        case .unknown: "Unknown"
        }
    }

    /// Detects the type from the first bytes of a file (8 bytes suffice).
    public static func detect(head: Data) -> DetectedFileType {
        let b = Array(head.prefix(8))
        guard b.count >= 2 else { return .unknown }
        if b[0] == 0x23, b[1] == 0x21 { return .script }                      // "#!"
        if b[0] == 0x4D, b[1] == 0x5A { return .pe }                          // "MZ"
        guard b.count >= 4 else { return .unknown }
        if b[0] == 0x7F, b[1] == 0x45, b[2] == 0x4C, b[3] == 0x46 { return .elf }
        if b[0] == 0x25, b[1] == 0x50, b[2] == 0x44, b[3] == 0x46 { return .pdf }    // "%PDF"
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        switch magic {
        case 0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE:
            return .machO
        case 0xCAFEBABE, 0xCAFEBABF:
            // Shared with Java class files; a fat header's nfat_arch is tiny
            // whereas a class file's version word is >= 45.
            guard b.count >= 8 else { return .machO }
            let word = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            return word < 0x30 ? .machO : .unknown
        default:
            return .unknown
        }
    }
}
