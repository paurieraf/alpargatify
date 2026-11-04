# Spec Delta

## Purpose

Reconcile one release, or the whole library, across the four local stores and the Navidrome view, so a partial or inconsistent import is reported as a named track list instead of a silent success.

## ADDED Requirements

### Requirement: Per-release reconciliation across five views
The doctor SHALL report, for a named release, which tracks are present in each of the five views it compares: the lossless tree, the lossless beets database, the lossy tree, the lossy beets database, and the Navidrome library. It SHALL name the tracks that are short, not just the counts.

#### Scenario: Release imported only partially into the lossy tree
- **WHEN** a release has 10 tracks on disk in the lossless tree and in both databases, but only 3 tracks in the lossy tree
- **THEN** the report shows the seven missing tracks with disc and track number, and the run exits with the "findings" status

#### Scenario: All five views agree
- **WHEN** every view holds the same 10 tracks for the release
- **THEN** the report marks the release as consistent and the run exits with the "clean" status

#### Scenario: Release unknown to every store
- **WHEN** the requested release matches no album in any view
- **THEN** the run exits with the "unknown release" status and prints no per-view detail

### Requirement: Disc folders belong to one release
The doctor SHALL treat every disc folder of a multi-disc release as part of a single release, resolving the release from the album identity recorded by beets and, for the Navidrome view, from the album identity reported by the Navidrome API.

#### Scenario: Two disc folders, one album
- **WHEN** a release is stored as `Disc 01` with 9 tracks and `Disc 02` with 1 track
- **THEN** the report lists 10 tracks for that one release and does not report either folder as an incomplete release

#### Scenario: Release split into several Navidrome albums
- **WHEN** the Navidrome view exposes the same release as more than one album
- **THEN** the report raises a split-release finding naming each album

### Requirement: Track paths must be library-relative and real
The doctor SHALL report any database row whose stored path is absolute or whose file is absent, distinguishing rows that are unusable for playback from rows whose file merely drifted in name.

#### Scenario: Rows left pointing at the import staging area
- **WHEN** the lossy database holds rows whose paths start with the container import mount instead of the library root
- **THEN** each row is reported as an orphan path finding with its album id and track number

#### Scenario: Row for a file that is gone
- **WHEN** a database row names a relative path with no file on disk
- **THEN** the row is reported as a missing file finding, attributed to the store that owns that database

### Requirement: Navidrome view is read from a snapshot, never live
The doctor SHALL read the Navidrome library from a database file passed by the operator and SHALL open it read-only, so that neither the file nor its journal or shared-memory companions are modified. The reported library root SHALL be mapped to a real directory before any comparison.

#### Scenario: Snapshot given on the command line
- **WHEN** the operator passes a Navidrome database snapshot and a mapping from the library root to a local directory
- **THEN** the report compares that snapshot against the local trees and leaves the snapshot byte-identical

#### Scenario: File is not a Navidrome database
- **WHEN** the given file lacks the expected Navidrome schema
- **THEN** the run stops with the "usage" status and a message naming the file, without touching any other store

#### Scenario: Library root not mapped
- **WHEN** a snapshot is given without a mapping for its library root
- **THEN** the run stops with the "usage" status rather than reporting every file as missing

### Requirement: Orphan and ghost detection in the Navidrome view
The doctor SHALL report release folders that exist on disk but that Navidrome does not know, and Navidrome albums whose folder no longer exists, as separate findings.

#### Scenario: Album on disk that Navidrome never scanned
- **WHEN** a release folder exists in the lossy tree with tracks and no Navidrome album matches it
- **THEN** the report raises an "absent from Navidrome" finding for that release

#### Scenario: Navidrome album whose files are all gone
- **WHEN** every file of a Navidrome album is absent from the local tree
- **THEN** the report raises a "ghost album" finding and states that the album is a purge candidate

### Requirement: Machine-readable report and stable exit statuses
The doctor SHALL emit a single JSON document on request, with the release, the five views, per-view counts, the short track list, and a findings array carrying a stable code and a severity. It SHALL exit with a distinct status for clean, findings, usage error, and unknown release.

#### Scenario: JSON consumed by a script
- **WHEN** the JSON output is requested
- **THEN** standard output contains one parseable JSON document and the exit status still distinguishes clean from findings

#### Scenario: Noisy tool banner before the payload
- **WHEN** an external command used to read the Navidrome view prints a banner before its own output
- **THEN** the JSON document remains the only structured payload and is still parsed correctly

#### Scenario: Findings present
- **WHEN** at least one finding of severity error is raised
- **THEN** the exit status is the "findings" status even if the JSON output was requested

### Requirement: The doctor never writes to any store
The doctor SHALL NOT create, modify, move, or delete any file in the lossless tree, the lossy tree, either beets database, or the Navidrome snapshot.

#### Scenario: Read-only run on a mounted library
- **WHEN** the doctor runs against a library whose mounts are read-only
- **THEN** the run completes normally and reports the same findings as a run against a writable mount

#### Scenario: Mass event visible in the Navidrome view
- **WHEN** the number of files Navidrome reports as missing exceeds the configured alarm threshold
- **THEN** the report raises a mass-missing finding and still exits without writing anything
