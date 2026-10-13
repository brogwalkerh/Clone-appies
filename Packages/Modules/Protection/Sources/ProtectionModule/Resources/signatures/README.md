# Bundled starter signatures

These files make Protection work offline on first launch (ADR 0006). They are
deliberately tiny; the real feed replaces them through `SignatureUpdater`.

## Provenance
- `starter.hdb` / `starter.hsb`: MD5 and SHA-256 of the 68-byte EICAR
  anti-malware test file, published by the European Institute for Computer
  Antivirus Research for exactly this purpose. The file is harmless.
- `starter.ndb`: the EICAR string as a hex body pattern, plus four
  `MacCleaner.Test.*` markers that match only the literal strings
  `MACCLEANER-TEST-MARKER-A`, `MACCLEANER-TEST-...-WILDCARD`,
  `#!...MACCLEANER-SCRIPT` (target 7, ASCII) and `MACCLEANER-MACHO-TEST`
  (target 9, Mach-O). They exercise the pattern grammar (fixed bytes, bounded
  skip ranges, `*`, absolute offsets, target filtering) and contain no bytes
  from real malware.

Formats are ClamAV's text formats: `.hdb` (`md5:size:name`), `.hsb`
(`sha256:size:name`), `.ndb` (`name:target:offset:hexpattern`), `.ign2`
(signature names to ignore).

## License note
Signature *data* that the feed later redistributes from the ClamAV project is
licensed under the GNU General Public License, version 2, as published by
Cisco Systems and the ClamAV contributors; we attribute it in the feed README
and pass it through unmodified apart from filtering. The starter files in this
directory were authored for this project and contain no ClamAV data. The
Swift code around them stays under this repository's license.
