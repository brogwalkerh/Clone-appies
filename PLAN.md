# Plan: court-ready export of macOS Messages

**Working name:** Messages Evidence Exporter (final name TBD)
**Target:** macOS 14 Sonoma through macOS 26 Tahoe, Apple silicon and Intel
**License:** GPL-3.0 (this repository)
**Status:** Planning. No code yet.

This plan is driven by the legal research in [`docs/legal-requirements-california.md`](docs/legal-requirements-california.md). Requirement IDs of the form **LR-n** refer to that document. Read it first; the design choices below only make sense against it.

---

## 1. Problem statement

People in California disputes (family law, civil, employment, criminal defense) routinely need to put their own iMessage / SMS history in front of a court. What they usually bring is screenshots, which are easy to attack: incomplete (Evid. Code § 1521 "unfair"), no metadata, no way to show they were not altered, and the §§ 1552/1553 presumption of accuracy collapses the moment the other side points at a gap (*People v. Rekte*).

Commercial forensic suites solve this but cost thousands of dollars and need an examiner. Hobbyist exporters (notably `imessage-exporter`) parse the database well but produce output with no evidentiary scaffolding: no hashes, no chain of custody, no declaration, no disclosure of limitations.

**Goal:** a native macOS app that a device owner (or their attorney or a paralegal) can run on the device itself to produce an export package that (a) is complete and accurate, (b) proves its own integrity, (c) gives a lay witness everything they need to lay the foundation under Evidence Code §§ 1400–1421, 1552–1553 and CCP § 2015.5, and (d) can be independently verified by the opposing party without trusting us.

**Explicit non-goals (v1):**
* Extracting data from an iPhone directly, or from locked/encrypted iOS backups (the user can enable Messages in iCloud or Text Message Forwarding so the Mac has the data; iOS backup support is a later phase).
* Carving deleted messages out of free SQLite pages or WAL frames beyond what Apple's own "Recently Deleted" table exposes. This is expert-witness territory and would invite a *Kelly* challenge; we flag that it is possible and leave it to a forensic examiner.
* Exporting other people's accounts. The app runs against the current macOS user's Messages data unless the user explicitly points it at another database and attests to authority (LR-20, LR-22).
* Legal advice. The app produces documents and a method description; what to file and how to argue it is counsel's job, and every generated document says so.

## 2. Users and the moments that matter

| User | Situation | What they need |
|---|---|---|
| Self-represented litigant | Family-law RFO, DV restraining order, small claims | One-click complete export of a conversation, a PDF they can attach, a declaration they can sign, plain-English instructions. |
| Attorney / paralegal | Preparing exhibits, responding to discovery | Selectable date ranges and participants with disclosed criteria, Bates numbering, redaction with a log, JSON for review platforms, a declaration for the client to sign. |
| Opposing counsel / their expert | Checking the export | A verification tool and manifest they can run themselves; a method description they can test. |
| Judge / clerk | Receiving the exhibit | PDF/A, text-searchable, bookmarked, exhibit index (CRC 2.256, 3.1110). |

## 3. How the legal rules shape the design

| Legal rule | Design consequence |
|---|---|
| §§ 1552/1553 presumption is rebuttable; once rebutted the proponent must prove accuracy by a preponderance | Collect affirmative proof up front: hash the source files before reading them, hash every output, log every step. Never rely on the presumption alone. |
| § 1521(a)(2): exclude secondary evidence if admission would be unfair | Default to complete conversations. Any filtering is printed on the exhibit with counts. The full JSON export always accompanies a filtered PDF. |
| § 1402: account for alterations | Redaction produces a new file, marked, logged; the unredacted package remains and its hash is referenced. |
| §§ 1420/1421: reply and content authentication | Preserve order, threading, reply-to links, full content, attachments, reactions, edits. |
| *Hawkins* / *Nazary*: machine data is not hearsay but needs a foundation that the system worked | Record macOS version, Messages version, database schema version, clock status (NTP sync, time zone), app version and build hash in the report. |
| *Lugashi* / *Dawkins*: a lay "qualified witness" is enough if they understand the system generally | Ship a Method and Process appendix written for a non-engineer, plus a short "how to testify about this export" guide. |
| CCP § 2015.5 | Declaration template uses the statutory form verbatim and asks where it was signed. |
| FRE 902(14) | Optional certification referencing the SHA-256 values, for federal court or as a gold-standard attachment in state court. |
| Pen. Code §§ 502, 631, 632 | Authority attestation gate; provenance warnings; everything runs offline. |
| CRC 2.256 / 3.1110 | PDF/A-2b, real text (not images of text), bookmarks per exhibit, exhibit index page. |

## 4. Architecture

Three deliverables, one codebase:

```
+----------------------------------------------------------------+
|  MessagesEvidence.app (SwiftUI)                                |
|  case management, acquisition wizard, preview, selection,      |
|  redaction, export, declaration generator                      |
+----------------------------------------------------------------+
|  EvidenceCore (Swift package, no UI)                           |
|   Acquisition  | Parser | Model | Renderers | Integrity | Audit|
+----------------------------------------------------------------+
|  mev (command-line tool, same package)                         |
|   mev acquire | mev export | mev verify | mev describe         |
+----------------------------------------------------------------+
|  mev-verify (standalone verifier; also builds on Linux)        |
+----------------------------------------------------------------+
```

### 4.1 Language and stack

**Swift 6, SwiftUI, Swift Package Manager.** Reasons:
* Full Disk Access, notarization, Gatekeeper, and the Contacts framework are all simplest from a native app.
* `attributedBody` is a legacy NeXTSTEP typedstream (`NSArchiver`). On macOS, Foundation's `NSUnarchiver` still decodes it into an `NSAttributedString` in one call, which avoids reimplementing the format. A pure-Swift typedstream parser (ported from `imessage-exporter`'s Rust implementation) is the fallback for the verifier, which must also build on Linux.
* Swift is close enough to C# that the maintainer's background transfers directly.

Key dependencies (all permissively licensed or GPL-compatible):
* **SQLite** via the system `libsqlite3` with a thin Swift wrapper (or GRDB.swift, MIT). Opened with `SQLITE_OPEN_READONLY` on our own copy, never on the live file.
* **CryptoKit** for SHA-256 and Ed25519 (system framework).
* **PDFKit / Core Graphics** for PDF rendering, plus a small PDF/A post-processor (embed fonts, XMP metadata, output intent). If PDF/A conformance from Core Graphics proves unreliable, fall back to generating PDF through a vendored copy of a permissively licensed library.
* **Contacts framework** for optional handle-to-name resolution (read-only, user-granted).
* Optional: `imessage-database` Rust crate from `imessage-exporter` (GPL-3.0, license-compatible) behind a C FFI if the Swift parser falls behind on new message types. Decision deferred to Phase 1 exit.

### 4.2 Acquisition (LR-1, LR-2, LR-3, LR-16, LR-20, LR-22)

1. **Authority gate.** The wizard asks the user to confirm, by typing their name, that they own or are authorized to access this Messages account. Stored in the audit log and reproduced in the declaration.
2. **Preflight.** Check Full Disk Access; detect macOS version, Messages app version, database schema (presence of `thread_originator_guid`, `date_edited`, `date_retracted`, `chat_recoverable_message_join`), iCloud Messages status (best effort via `defaults`), "Keep messages" retention setting, time zone, NTP sync status. Advise the user to quit Messages so the WAL is quiescent; do not force it.
3. **Copy, then hash, then read.** Copy `chat.db`, `chat.db-wal`, and `chat.db-shm` byte-for-byte into `<case>/acquisition/<timestamp>/source/`. Also copy `~/Library/Messages/Attachments/` (optionally, with size estimate) and, if present, `NickNameCache` and `chat.db`-adjacent sticker/handwriting stores. Record file sizes, mtimes, and SHA-256 of each file in `manifest.json` **before** opening anything.
4. **Consolidate.** On a second copy (`working/`), open read-write once to run `PRAGMA wal_checkpoint(TRUNCATE)` then `VACUUM INTO 'consolidated.db'`; hash `consolidated.db`; thereafter open only that file read-only. The original three files are never opened by SQLite, so their hashes stay valid. (Opening a WAL database with `immutable=1` would ignore the WAL and silently drop the newest messages; we avoid that mode entirely.)
5. **Audit log entry** for every step, including any warnings (Messages was running, WAL non-empty, attachments missing on disk, database belongs to another user).

Acquisition is **always complete**. There is no "export just this chat" at this stage; selection is an export-time concern so that the complete, hashed source always exists (LR-4).

### 4.3 Parser (LR-6, LR-7, LR-8, LR-9, LR-11, LR-12)

Reads `consolidated.db` into the canonical model. Must handle:
* `message.text` null with body in `attributedBody` (macOS 13+); mentions, links, and styled runs preserved as spans.
* Apple epoch: `date` is nanoseconds since 2001-01-01 UTC on modern databases, seconds on old ones; detect by magnitude; treat 0, negative, and INT64 sentinels as "no timestamp."
* `is_from_me`, `handle_id`, `service` (iMessage / SMS / MMS / RCS / Satellite), `date_delivered`, `date_read` with direction-dependent semantics.
* Reactions: rows with `associated_message_type` 2000–2999 (added) and 3000–3999 (removed), including 2006 custom-emoji and 2007 sticker tapbacks; attach to the target by `associated_message_guid`, never emit as standalone messages.
* Replies/threads via `thread_originator_guid` and part index.
* Edits via `date_edited` and `message_summary_info` (full history with per-edit timestamps); unsends via `date_retracted`.
* Recently Deleted via `chat_recoverable_message_join`, flagged.
* System events (`item_type != 0`, `group_action_type`): participant added/removed, name change, group photo change, rendered as events not statements.
* Attachments via `message_attachment_join` and `attachment` (`filename`, `transfer_name`, `mime_type`, `total_bytes`, `is_sticker`); detect missing-on-disk (offloaded to iCloud) and record that fact.
* Multi-part messages, audio-message transcripts if present, Apple Pay / app balloons (`balloon_bundle_id`) rendered as "[App message: <bundle>]" with payload hash.
* Duplicate chats for the same handle set (phone vs. email) listed separately but cross-referenced; never silently merged, because merging is an interpretive step a witness would have to explain.

Every parsed message carries its source `ROWID` and `guid` so any rendered line can be traced back to a row in the hashed database.

### 4.4 Canonical model and JSON export (LR-19)

A versioned JSON schema (`evidence-export/1.0`) that is the single source for every renderer. Sketch:

```json
{
  "schema": "evidence-export/1.0",
  "package_id": "uuid",
  "acquisition": { "timestamp_utc": "...", "operator": "...", "host": {...}, "source_files": [{"path": "...", "sha256": "...", "bytes": 0}] },
  "account": { "handles": ["+1415...", "user@icloud.com"], "macos_user": "..." },
  "chats": [{
    "chat_rowid": 12, "guid": "iMessage;+;chat123", "display_name": null, "service": "iMessage",
    "participants": [{"handle_rowid": 3, "id": "+14155551212", "contact_name": "Jane Doe", "contact_source": "Contacts.app"}],
    "message_count_total": 4821, "message_count_exported": 4821, "selection": null
  }],
  "messages": [{
    "rowid": 90210, "guid": "...", "chat_rowid": 12, "sender": {"handle_rowid": 3, "id": "+14155551212"}, "is_from_me": false,
    "sent_utc": "2025-03-04T18:22:01.123Z", "sent_local": "2025-03-04T10:22:01-08:00", "tz": "America/Los_Angeles",
    "delivered_utc": null, "read_utc": "...", "service": "iMessage",
    "body": {"text": "...", "spans": [...]}, "edits": [{"edited_utc": "...", "text": "..."}], "retracted_utc": null,
    "reply_to_guid": null, "reactions": [{"type": "love", "by": "+1415...", "utc": "..."}],
    "attachments": [{"attachment_rowid": 7, "filename": "IMG_0001.heic", "mime": "image/heic", "sha256": "...", "present_on_disk": true}],
    "recoverable_deleted": false, "item_type": 0
  }],
  "limitations": ["icloud_sync_enabled", "retention_30_days", "..."]
}
```

### 4.5 Renderers (LR-17, LR-18)

* **Exhibit PDF (PDF/A-2b).** Cover page: case caption fields (blank by default), exhibit number, package ID, SHA-256 of this PDF (written into the file after rendering using a two-pass approach: the hash shown is of the final file excluding the hash field, with the method explained in the appendix), acquisition date, operator, selection criteria and counts. Body: one conversation per section, chronological, every message with local and UTC time, sender handle + resolved name, service, delivery/read markers, reactions inline, edits as a numbered history, unsends and deletions marked, attachments embedded as images (HEIC converted to JPEG, with original hash printed) or as a placeholder with hash and filename for non-images. Footer: Bates number `PREFIX-000001`, page x of y, package ID. Bookmarks: per exhibit, per conversation, per month. Exhibit index as the first page after the cover.
* **Attachments exhibit.** Each attachment as its own bookmarked sub-exhibit with original file hash, size, MIME type, message reference; video gets a contact sheet of frames plus the hash of the original file; audio gets the transcript if Messages stored one.
* **Plain text transcript.** For the self-represented litigant and for diffing.
* **Declaration (DOCX and PDF).** CCP § 2015.5 form, fields pre-filled from the manifest: declarant, device, macOS user account, handles, acquisition timestamp, app version and build hash, source and output hashes, statement of non-alteration, selection and redaction statements, limitations paragraph, place of signing or "under the laws of the State of California" variant.
* **FRE 902(14) certification (optional).**
* **Method and Process appendix.** Generated from a maintained template with the actual versions and hashes substituted; explains how Messages stores data, what the tool copies, how it hashes, how it converts timestamps, what it cannot see.
* **Chain-of-custody form.** Pre-filled first row (acquisition), blank rows for later transfers, per SWGDE.

### 4.6 Integrity layer (LR-3, LR-16, LR-23)

* `manifest.json` lists every file in the package with SHA-256 and byte length; the manifest is itself hashed and the hash is printed on the PDF cover and in the declaration.
* `audit.jsonl` is append-only; each line includes the SHA-256 of the previous line (a simple hash chain) so deletions or reordering are detectable.
* Optional Ed25519 signature of the manifest with a key generated on first run and stored in the user's Keychain. This proves "the same installation produced this package," nothing more; the document says so.
* `mev-verify <package>` recomputes every hash, checks the audit chain, re-parses `consolidated.db` and diffs it against `export.json`, and prints a pass/fail report. It has no dependency on the app, no network access, and builds on macOS and Linux so an opposing expert can run it anywhere.

### 4.7 Redaction (LR-5)

Redaction works on the canonical model, not on the PDF. The user selects messages, attachments, or regex matches (e.g., SSNs, account numbers); the tool produces a second package `redacted/` whose PDF shows `[REDACTED: <reason code>]` blocks with message ROWIDs still visible, and whose `redaction-log.json` lists every redaction with ROWID, reason, operator, timestamp. The unredacted package hash is referenced so the court can order it produced in camera.

### 4.8 Contact resolution (LR-9)

Off by default. When enabled, names come from Contacts.app via the Contacts framework, and each resolved name records its source and the contact record identifier. The raw handle is always printed alongside. The declaration includes a sentence explaining the resolution.

## 5. Package layout

```
<CaseName>-<PackageID>/
  manifest.json
  manifest.sha256
  audit.jsonl
  acquisition/
    source/chat.db, chat.db-wal, chat.db-shm      (untouched, hashed)
    source/Attachments/...                          (untouched, hashed)
    working/consolidated.db                         (hashed)
    environment.json                                (macOS, Messages, schema, tz, clock)
  export/
    export.json
    Exhibit-A.pdf
    Exhibit-A-attachments.pdf
    transcript.txt
    attachments/<sha256>.<ext>                      (converted copies for viewing, originals in acquisition/)
  declarations/
    declaration-ccp-2015.5.docx / .pdf
    certification-fre-902-14.docx / .pdf
    method-and-process.pdf
    chain-of-custody.pdf
  redacted/                                         (only if redaction was used)
```

## 6. Phases and deliverables

### Phase 0 — Foundations (1–2 weeks)
* Repository skeleton: Swift package `EvidenceCore`, CLI `mev`, app target, CI on macOS runners.
* Test fixtures: anonymized `chat.db` samples from macOS 13, 14, 15, 26 covering every message type listed in 4.3. Generate synthetic ones with a script that drives a real Messages install in a VM where possible.
* Attorney review of `docs/legal-requirements-california.md` (budget for an hour of a California litigator's time). Adjust LR list.
* Decide PDF/A strategy by spiking Core Graphics output through a validator (veraPDF).

**Exit:** fixtures hashed and committed; LR list signed off.

### Phase 1 — Acquire and parse (3–4 weeks)
* `mev acquire` implementing 4.2 end to end with manifest and audit log.
* Parser for the full model in 4.3, with golden-file tests per fixture.
* `mev export --json` producing `export.json`.
* `mev describe` printing environment and limitations.

**Exit:** every fixture round-trips; parser output matches `imessage-exporter` on the same fixture for text, timestamps, reactions, and edits (used as an independent cross-check, documented in the method appendix).

### Phase 2 — Render and declare (3–4 weeks)
* Exhibit PDF/A renderer with bookmarks, Bates numbers, index, cover hash.
* Attachments exhibit with HEIC/MOV conversion and original-hash printing.
* Declaration, 902(14) certification, method appendix, chain-of-custody templates.
* `mev-verify` with Linux build and a README written for an opposing expert.

**Exit:** a package produced from a fixture passes veraPDF, passes `mev-verify`, and a mock "opposing expert" review (someone not on the project) can reproduce the export from the package alone.

### Phase 3 — App (4–6 weeks)
* SwiftUI app: case list, acquisition wizard with authority gate and preflight, conversation browser with search, selection with live counts, redaction UI, export, declaration fill-in, "how to testify" guide.
* Notarized, Developer ID signed, Full Disk Access onboarding.

**Exit:** usability test with two self-represented users and one paralegal; they can produce a package and a signed declaration without help.

### Phase 4 — Hardening and release (2–3 weeks)
* Adversarial tests: tamper with a byte of `consolidated.db`, drop a WAL frame, edit `export.json`, reorder `audit.jsonl`; verifier must fail each.
* Clock tests: wrong time zone, DST boundaries, pre-2001 sentinels, seconds-vs-nanoseconds databases.
* Reproducibility: two runs on the same fixture produce byte-identical `export.json` and identical PDF text layer (PDF binary may differ only in the acquisition timestamp fields).
* Documentation: user guide, method appendix source, verifier guide, limitations page.
* Second attorney review of generated declarations.

**Later phases (not scheduled):** iOS backup input (unencrypted first), carved-deletion recovery as a clearly separated "forensic examiner mode," per-county exhibit stamp presets, Spanish-language declarations.

## 7. Testing strategy

| Layer | What | Traces to |
|---|---|---|
| Unit | timestamp conversion, typedstream decoding, reaction mapping, edit history | LR-6, LR-7, LR-8 |
| Golden files | each fixture → `export.json` snapshot | LR-4, LR-19 |
| Cross-check | parity with `imessage-exporter` on fixtures | LR-14 (independent method) |
| Integrity | tamper suite; verifier must fail | LR-3, LR-16, LR-23 |
| Format | veraPDF PDF/A-2b validation; bookmark presence; text layer extractable | LR-17 |
| Acquisition | WAL-with-pending-frames fixture: messages present only in WAL must appear | LR-2 |
| Read-only | file-system watcher asserts no writes under `~/Library/Messages` during a run | LR-1 |
| Human | attorney review of declarations; non-project engineer reproduces export from package | LR-13, LR-14, LR-15 |

## 8. Risks and open questions

* **PDF/A from Core Graphics.** Apple's PDF output is not PDF/A by default. Mitigation: spike in Phase 0; fall back to a vendored library.
* **`NSUnarchiver` deprecation.** Still present through macOS 26 but could be removed. Mitigation: pure-Swift typedstream parser is on the roadmap regardless because the verifier needs it on Linux.
* **Schema drift.** Apple changes `chat.db` yearly. Mitigation: fixtures per macOS version, `PRAGMA table_info` feature detection, loud failure on unknown `associated_message_type` values rather than silent drop.
* **iCloud completeness.** The local database may not be the whole account history. We cannot fix this; we disclose it (LR-24) and recommend the user enable "Download Attachments" and let sync finish before acquisition.
* **Over-promising.** Nothing the tool does guarantees admission; attribution still depends on the witness. Every generated document carries a limitations paragraph and a "not legal advice" line.
* **Open question for counsel:** whether courts in the target counties want the attachments as separate exhibits or inline; whether a Bates prefix should be configurable per exhibit or per package.
* **Open question for product:** should the app refuse to run on a database it detects as belonging to another macOS user, or only warn (current plan: warn and require a second attestation).

## 9. Immediate next steps

1. Get a California litigator to read `docs/legal-requirements-california.md` and mark anything wrong or missing.
2. Build the fixture set (Phase 0). This is the long pole; start it now.
3. Spike PDF/A output and typedstream decoding in a throwaway Swift package to retire the two biggest technical risks before Phase 1.
