# California legal requirements for text-message evidence

**Purpose.** This document collects the California (and, where relevant, federal) rules that govern whether an export of macOS Messages data can be received in evidence, and turns them into concrete product requirements for the exporter. It is research, not legal advice. Every citation should be re-checked against the current text at leginfo.legislature.ca.gov before it is relied on in a filing.

**Status.** Researched 2026-10-13 from the Judicial Council / CJER judicial-education handouts ("It's on My Phone" and "'It's really important' is not found in the Evidence Code"), the statutory text they reproduce, and practitioner commentary. Where a source was secondary, that is noted.

---

## 1. The framework a California court applies

California judges are taught to run electronic writings through the "R‑A‑S‑H" sequence:

| Step | Rule | What the proponent must show |
|---|---|---|
| **R**elevance | Evid. Code §§ 210, 350–352 | The message tends to prove a disputed fact; not unduly prejudicial or time-consuming. |
| **A**uthentication | Evid. Code §§ 1400–1421 | Enough evidence for a trier of fact to find the writing is what the proponent says it is. |
| **S**econdary evidence | Evid. Code §§ 255, 1520–1523, 1552–1553 | A copy/printout is acceptable, subject to a fairness check, and printouts of computer data are presumed accurate. |
| **H**earsay | Evid. Code §§ 1200, 1220–1221, 1271 | The message is not offered for its truth, or an exception applies (most often party admission). |

A text message is a "writing" under Evid. Code § 250 ("every other means of recording ... any form of communication ... regardless of the manner in which the record has been stored"). Nothing about texts or iMessages gets special treatment; the ordinary rules apply.

## 2. Authentication (Evid. Code §§ 1400–1421)

### 2.1 Standard

* § 1400: authentication is "the introduction of evidence sufficient to sustain a finding that it is the writing that the proponent of the evidence claims it is."
* § 1401: required before the writing, or any secondary evidence of its content, is received.
* The burden is a **prima facie** showing. "As long as the evidence would support a finding of authenticity, the writing is admissible. The fact conflicting inferences can be drawn regarding authenticity goes to the document's weight as evidence, not its admissibility." (*People v. Goldsmith* (2014) 59 Cal.4th 258, 267.)
* "The proponent's threshold authentication burden for admissibility is not to establish validity or negate falsity in a categorical fashion, but rather to make a showing on which the trier of fact reasonably could conclude the proffered writing is authentic." (*People v. Valdez* (2011) 201 Cal.App.4th 1429, 1435.)
* The required foundation "varies with the nature of the evidence ... and with the degree of possibility of error." The first step is to identify the purpose for which the evidence is offered. (*Goldsmith*, at 267.)

### 2.2 Two distinct questions the export must help answer

Authentication of a text message has two layers, and the tool can only fully solve the first:

1. **Is this an accurate copy of what is on the device?** (reproduction accuracy). This is what the §§ 1552/1553 presumptions and a well-documented, hash-verified export address.
2. **Who wrote it?** (attribution). The presumption does not establish authorship. Attribution is shown by circumstantial evidence: the sender's phone number/email, contact name, content only the author would know (§ 1421), that the message came in reply to one sent to the claimed author (§ 1420), admissions (§ 1414), or testimony of someone who saw it sent (§ 1413). The export must **preserve and surface every datum a witness could use for this**, and must never silently substitute a contact name for the underlying handle.

### 2.3 Methods of authentication the export should support

| Section | Method | What the tool should produce |
|---|---|---|
| § 1410 | Article is not exclusive; any method works. | Flexibility: multiple output forms. |
| § 1411 | Testimony of the author/subscribing witness is **not** required. | The device owner can lay the foundation; no need for the other party to testify. (*Adoption of X.D.* (2025) 114 Cal.App.5th 812, as described in secondary sources: a screenshot forwarded by a third party was authenticated by number match, nickname, and content; opinion should be read directly.) |
| § 1413 | Witness who saw the writing made. | Device owner's declaration that they sent/received the messages. |
| § 1414 | Admission or reliance by the opposing party. | Not a tool feature; note in guidance. |
| § 1420 | Evidence of reply. | Export must keep **conversation order and threading** so a reply can be tied to the message it answers. |
| § 1421 | Content known only to the author. | Export must reproduce **full, unedited content** including attachments, links, reactions, edits. |
| § 1402 | Altered writings must be accounted for. | Any redaction or omission must be disclosed on the face of the exhibit and in a redaction log; source data is never changed. |

### 2.4 Case law on electronic evidence (from the Judicial Council handouts)

* *People v. Goldsmith* (2014) 59 Cal.4th 258 — red-light camera images; photographs/data are substantive "silent witness" evidence; §§ 1552/1553 presumptions establish, at least preliminarily, that "errors in content have not been introduced in the course of printing"; secondary evidence rule does not excuse authentication.
* *People v. Beckley* (2010) 185 Cal.App.4th 509 — MySpace photo/gang roster excluded for insufficient authentication; suggested a need for author testimony or expert testimony on non-manipulation. Later courts treat this as an "archaic view."
* *People v. Valdez* (2011) 201 Cal.App.4th 1429 — MySpace page authenticated by circumstantial evidence (password protection, consistent content); distinguished *Beckley*.
* *In re K.B.* (2015) 238 Cal.App.4th 989 — Instagram screenshots authenticated by circumstantial evidence; refused to endorse a rule requiring the creator's testimony or an expert on non-alteration; "any competent witness with sufficient familiarity" can lay the foundation.
* *Kinda v. Carpenter* (2016) 247 Cal.App.4th 1268 — Yelp posts and ISP records; only a prima facie showing is required; conflicting inferences go to weight.
* *People v. Chism* (2014) 58 Cal.4th 1266 — § 1553 presumption applies even to enhanced/cropped images; prosecution accounted for omitted portions.
* *People v. Rekte* (2015) 232 Cal.App.4th 1237 — defendant **successfully rebutted** the §§ 1552/1553 presumptions. The presumption is real but fragile: once rebutted, the proponent must prove accuracy by a preponderance.
* *People v. Catlin* (2001) 26 Cal.4th 81 — chain of custody.
* *Meeks v. AutoZone, Inc.* (2018) 24 Cal.App.5th 855 — testimony about the contents of unavailable text messages may be admissible under § 1523; relevant to "what if the messages are gone."
* *Ramos v. Westlake Services LLC* (2015) 242 Cal.App.4th 674, 684 — "a writing can be authenticated by circumstantial evidence and by its contents."

## 3. Secondary evidence and printouts (Evid. Code §§ 255, 1520–1523, 1552–1553)

* § 255: if data are stored in a computer, "any printout or other output readable by sight, shown to reflect the data accurately, is an 'original.'" An accurate export is therefore an **original**, not merely a copy.
* § 1520–1521: content may be proved by an original or by otherwise admissible secondary evidence; the court **must** exclude secondary evidence if (1) a genuine dispute exists over material terms and justice requires exclusion, or (2) admission would be **unfair**. Incomplete or cherry-picked screenshots are the classic "unfair" target. § 1521(c): authentication is still required.
* § 1523: oral testimony about the content of a writing is generally inadmissible, with narrow exceptions (lost/destroyed original without fraudulent intent, not reasonably procurable, voluminous records).
* **§ 1552(a)**: "A printed representation of computer information or a computer program is presumed to be an accurate representation of the computer information or computer program that it purports to represent." Presumption affecting the burden of producing evidence; if the opponent introduces evidence of inaccuracy or unreliability, the proponent must prove accuracy **by a preponderance**.
* **§ 1553(a)**: same presumption for "a printed representation of images stored on a video or digital medium" (covers photo/video attachments).
* Practical consequence (*Hawkins*, *Goldsmith*): the presumptions only establish that "a computer's print function has worked properly." The tool must be ready for the presumption to be rebutted, which means the proponent needs **affirmative proof of accuracy**: hashes of the source database and of every output, an audit log of what was done, a description of the method, and a witness who ran the collection and generally understands the system.

## 4. Hearsay (Evid. Code §§ 1200, 1220, 1221, 1271; *Hawkins*; *Nazary*)

* Messages offered for their truth are hearsay (§ 1200) unless an exception applies. The most common exception is the **party admission** (§ 1220) for messages written by the opposing party, and **adoptive admission** (§ 1221) for the party's responses.
* **Machine-generated data is not hearsay.** Timestamps, delivery/read receipts, sender identifiers, and message GUIDs are generated by the system, not "statements" by a person (*People v. Hawkins* (2002) 98 Cal.App.4th 1428; *People v. Nazary* (2010) 191 Cal.App.4th 727). Their admissibility is foundational: was the system operating properly? Questions about accuracy go to weight (*People v. Dawkins* (2014) 230 Cal.App.4th 991: a witness with general knowledge of an automated system may testify to having downloaded the information; no "elaborate showing" of accuracy is required).
* **Qualified witness.** For computer records, "a person who generally understands the system's operation and possesses sufficient knowledge and skill to properly use the system and explain the resultant data" is a qualified witness; no programmer or expert is required (*People v. Lugashi* (1988) 205 Cal.App.3d 632, as applied in *People v. Rodriguez* (2016) 16 Cal.App.5th 355). The tool's documentation must be written so that an ordinary user can give this testimony.
* **Business records (§ 1271)** are usually not the right exception for personal texts, but the foundational elements (identity, mode of preparation, time of preparation, trustworthiness) are a useful checklist for what the export report should state. The custodian-affidavit template in § 1561(a) (custodian identity and authority; true copy of all records; prepared in the ordinary course at or near the time; identity of the records; mode of preparation) is a good model for the tool's generated declaration even though § 1561 itself applies to subpoenaed business records.

## 5. Declarations (Code Civ. Proc. § 2015.5)

An unsworn declaration can substitute for an affidavit if it is subscribed, states it is made under penalty of perjury, and either (a) is executed in California and states the date and place of execution, or (b) states that it is made "under the laws of the State of California" with the date. A declaration signed outside California without the "laws of the State of California" recital is non-compliant (*Kulshrestha v. First Union Commercial Corp.* (2004) 33 Cal.4th 601). The tool's generated declarations must use the statutory form exactly.

## 6. Court-filing format (Cal. Rules of Court)

* Rule 2.256(b): electronically filed documents must be PDF, readable with generally available software, and **text-searchable when technologically feasible**.
* Rule 3.1110(f): an index of exhibits is required; electronic exhibits must have **bookmarks** to the first page of each exhibit with titles giving the exhibit number/letter and a brief description (self-represented litigants exempt).
* Rule 2.100(a): Judicial Council formatting rules preempt local rules, but local courts add e-filing requirements (e.g., LASC requires text-searchable PDF). Trial-courtroom presentation (screens, media players, "only the content to be shown") is governed by local practice and varies by county.
* Family Code § 217 / rule 5.113: in family law RFO hearings the court must receive live, competent, admissible testimony; the device owner should expect to be the authenticating witness.

## 7. Federal courts sitting in California (FRE 902(13), 902(14))

Federal courts apply the Federal Rules of Evidence, not the Evidence Code. Since December 1, 2017:

* **FRE 902(13)**: records generated by an electronic process or system are self-authenticating if accompanied by a certification of a qualified person that meets the 902(11) requirements.
* **FRE 902(14)**: data copied from an electronic device, storage medium, or file are self-authenticating "if authenticated by a process of digital identification" (the Advisory Committee Note names **hash values**) with the same kind of certification. The certifying person must be someone who could testify to authenticity at trial, and advance written notice must be given.

Even in state court these rules describe the gold standard the opponent's expert will measure the export against. The tool should generate a 902(14)-style certification as an optional output.

## 8. Lawful acquisition: whose messages may be exported

The rules of evidence say nothing about the tool, but California privacy statutes constrain **whose** device the tool may be run on, and illegally obtained evidence can be excluded or expose the user to liability.

* **Penal Code § 502(c)(2), (c)(7)**: knowingly accessing a computer, computer system, or computer network without permission, or taking/copying data from it without permission, is a crime and gives the owner a civil cause of action (§ 502(e): compensatory damages, injunctive relief, attorney's fees, punitive damages). Smartphones and Macs are "computer systems."
* **Penal Code § 631** (wiretapping) and **§ 632** (eavesdropping/recording confidential communications): § 632(d) excludes evidence obtained in violation of § 632 "in any judicial, administrative, legislative, or other proceeding." § 631 has been read broadly (*Ribas v. Clark* (1985) 38 Cal.3d 355), though courts generally distinguish reading **stored** messages from **intercepting** them in transit. Reading a spouse's or child's messages without authorization is a litigation risk even if § 631 does not technically apply.
* Family-law and employment contexts have additional wrinkles (shared Apple IDs, family-plan devices, employer-owned Macs). None of this is the tool's call to make, but the tool must (a) require the user to attest to their authority to access the data, (b) record that attestation and the identity of the account whose data was exported, and (c) warn before exporting a database that belongs to a different macOS user account.

## 9. Forensic practice standards (persuasive, not binding)

* **SWGDE** *Best Practices for Digital Evidence Collection* (18-F-002) and *Mobile Device Evidence Collection, Preservation, Handling and Acquisition* (18-F-003): contemporaneous chain-of-custody records with unique identifiers, date/time of receipt, and every transfer; secure evidence as soon as practical; document any deviation from best practice and why.
* **NIST SP 800-101 Rev. 1** *Guidelines on Mobile Device Forensics* (2014): validation, preservation, acquisition, examination, analysis, and reporting under forensically sound conditions; tool validation against known data.
* **ISO/IEC 27037**: identification, collection, acquisition, and preservation of digital evidence; principles of auditability, repeatability, reproducibility, and justifiability.
* **Hashing**: SHA-256 (or stronger) of every source and output file, computed at acquisition and re-verifiable by anyone; this is what FRE 902(14) and opposing experts expect.

## 10. Requirements derived from the research

Each requirement is tagged so the plan and test suite can trace to it.

### Accuracy and completeness (§§ 255, 1521, 1552, 1553, 1402)

* **LR-1** Acquisition must be read-only against the live Messages data; the tool never writes to `~/Library/Messages`.
* **LR-2** The acquisition must capture the full database including the write-ahead log (`chat.db-wal`), because the newest messages live there; omitting it silently drops evidence.
* **LR-3** Every source file and every output file must have a SHA-256 hash recorded in a manifest at the time it is created; the manifest must itself be hashed.
* **LR-4** The default export is the **complete** conversation(s). Selection by date range, participant, or keyword must be disclosed on the face of the exhibit, with total counts (messages in conversation vs. messages exported) and a statement of the selection criteria.
* **LR-5** Redaction never alters source data; it produces a separate output, marks each redaction visibly, and writes a redaction log (what was redacted, why, by whom, when).
* **LR-6** Edited messages must show the full edit history; unsent (retracted) messages must be noted in place; deleted-but-recoverable messages must be exported and flagged as such.
* **LR-7** Reactions (tapbacks), replies, threads, and attachments must be attributed to the correct sender and the correct target message, and must never be counted or rendered as free-standing messages.
* **LR-8** Timestamps must be rendered in both UTC and a stated local time zone, with the conversion rule documented, and sentinel/zero values rendered as "no timestamp," never as a date in 2001.

### Attribution evidence (§§ 1413, 1420, 1421)

* **LR-9** Every message must show the raw sender identifier (phone number or email handle) in addition to any resolved contact name, and the report must state where contact names came from.
* **LR-10** Conversation order and threading must be preserved exactly so reply relationships are visible (§ 1420).
* **LR-11** Group chats must list all participants, and participant changes/renames must be shown as system events, distinguished from human statements (*Hawkins*).
* **LR-12** Service (iMessage / SMS / MMS / RCS), delivery status, and read status must be shown, with an explanation of what `date_read` means for outgoing vs. incoming messages.

### Foundation witness support (§§ 1552, 1271, *Lugashi*, *Dawkins*, CCP § 2015.5)

* **LR-13** The tool must generate a declaration in CCP § 2015.5 form for the device owner / operator, stating: identity and authority; the device and macOS user account; the Apple ID / phone numbers associated with the Messages account; the date, time, and method of the export; that the declarant did not alter the data; and the hashes of the source and output.
* **LR-14** The tool must generate a plain-language "Method and Process" appendix describing how the software works, sufficient for a lay witness to be a *Lugashi* "qualified witness," and sufficient for an opposing expert to reproduce the result.
* **LR-15** The tool must generate an optional FRE 902(14)-style certification for federal proceedings.
* **LR-16** The tool must keep a contemporaneous, append-only audit log of every action taken in a case (acquisition, exports, redactions, re-verifications) with timestamps, operator, software version, and machine identity.

### Format (Cal. Rules of Court 2.256, 3.1110)

* **LR-17** Exhibit output must be PDF/A, text-searchable, with bookmarks per conversation / per exhibit, an exhibit index, Bates-style page numbering, and a header/footer carrying the case caption placeholder, exhibit number, and output hash.
* **LR-18** Attachments (images, video stills, audio transcripts, files) must be embedded or referenced in a way that satisfies § 1553 (printed representation of a stored image) and must carry their own hashes.
* **LR-19** A machine-readable export (JSON) must accompany every PDF so the other side can verify content without re-running the tool.

### Lawful acquisition and privacy (Pen. Code §§ 502, 631, 632)

* **LR-20** Before acquisition the user must attest to ownership of, or authority over, the Messages account being exported; the attestation is recorded in the audit log and in the declaration.
* **LR-21** The tool must run entirely on the local machine with no network access; no data is uploaded, telemetry is off by default.
* **LR-22** The tool must warn if the database being opened belongs to a different macOS user, a Time Machine backup, or an iOS backup, and record the provenance.

### Verifiability (FRE 902(14), *Rekte*)

* **LR-23** An independent, open-source verification tool must be able to confirm that an export package is intact (recompute hashes, check manifest, check audit log chain) without any secret or proprietary component.
* **LR-24** The tool must disclose, in every report, known limitations: iCloud sync means the local database may not be the complete account history; "Keep messages" retention settings may have deleted older messages; attachments may be offloaded; outgoing `date_read` is only populated when the recipient has read receipts on; carrier SMS may be forwarded from an iPhone and reflect its clock.

---

## Sources consulted

Primary / official:
* Judicial Council of California, CJER, "It's on My Phone — Table of Authorities" (Ratekin & Lucky, rev. 10/5/2015), https://courts.ca.gov/sites/default/files/courts/default/2024-08/social_media_handout2.pdf
* Judicial Council of California, CJER, "'It's really important' is not found in the Evidence Code," https://courts.ca.gov/system/files/file/its-really-important-handout-1.pdf
* Evid. Code § 1552, https://law.justia.com/codes/california/code-evid/division-11/chapter-2/article-3/section-1552/
* Evid. Code § 1521, https://california.public.law/codes/evidence_code_section_1521
* Evid. Code § 1561, https://california.public.law/codes/evidence_code_section_1561
* Pen. Code § 502, https://california.public.law/codes/penal_code_section_502
* Pen. Code § 632, https://california.public.law/codes/penal_code_section_632
* *Ribas v. Clark* (1985) 38 Cal.3d 355, https://scocal.stanford.edu/opinion/ribas-v-clark-30748
* *Kulshrestha v. First Union Commercial Corp.* (2004) 33 Cal.4th 601, https://scocal.stanford.edu/opinion/kulshreshta-v-first-union-33434
* Cal. Rules of Court 2.256 / 3.1110 rulemaking history, https://courts.ca.gov/system/files/file/jctc-20160825-materials-supplemental.pdf
* NIST SP 800-101 Rev. 1, https://csrc.nist.gov/pubs/sp/800/101/r1/final
* SWGDE 18-F-002 and 18-F-003, https://www.swgde.org/documents/published-complete-listing/

Secondary (verify before citing):
* Cotchett, Pitre & McCarthy, "Admissibility of Text Messages in California Courts" (on *Adoption of X.D.*), https://www.cpmlegal.com/blogs-Advocates-For-Justice/admissibility-of-text-messages-in-california-courts
* Beverly Hills Bar Assn. CLE, "You Texted What? Admissibility of Text Messages at Trial," https://bhba.org/cle/you-texted-what-admissibility-of-text-messages-at-trial/
* Advocate Magazine, "Laying the foundation for electronic and documentary evidence at trial," https://www.advocatemagazine.com/article/2015-october/laying-the-foundation-for-electronic-and-documentary-evidence-at-trial-2
* Plaintiff Magazine, "Admissibility of computer documents at trial," https://plaintiffmagazine.com/recent-issues/item/admissibility-of-computer-documents-at-trial
* Foley & Lardner, "New Federal Rules of Evidence 902(13) and 902(14)," https://www.foley.com/en/insights/publications/2017/12/new-federal-rules-of-evidence-90213-and-90214
* Forensic Focus on FRE 902(14), https://www.forensicfocus.com/legal/new-federal-rule-of-evidence-to-directly-impact-computer-forensics-and-ediscovery-preservation-best-practices/
* One Legal, "Required Formatting for eFiled Documents in California Superior Courts," https://support.onelegal.com/court-filing/what-is-the-required-formatting-for-efiled-documents
* ACFLS, "Penal Code § 632: The Dilemma of Secretly Recorded Evidence in Family Law," https://acfls.org/articles/california-penal-code-section-632-the-dilemma-of-secretly-recorded-evidence-in-family-law-and-abuse-cases

Technical (Messages database format):
* ReagentX/imessage-exporter features, https://github.com/ReagentX/imessage-exporter/blob/develop/docs/features.md
* ChatExport/ChatExportKnowledge (sms.db schema iOS 11–26, attributedBody, timestamps, read-receipt semantics), https://github.com/ChatExport/ChatExportKnowledge
* grio-co/imessage-exporter-redux SCHEMA.md, https://github.com/grio-co/imessage-exporter-redux/blob/main/docs/SCHEMA.md
* tyhallcsu/imessage-unsent (WAL-page recovery of unsent messages), https://github.com/tyhallcsu/imessage-unsent
