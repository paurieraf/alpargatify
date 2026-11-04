# Spec Delta

## Purpose

Remove a release from every store that knows it — both trees, both beets databases, and the Navidrome library — reversibly and with a bounded, verifiable purge.

## ADDED Requirements

### Requirement: Ordered, abortable removal sequence
The removal SHALL proceed through a fixed sequence of stages: preflight reconciliation, snapshot of the Navidrome database, removal of the beets rows, moving the files to trash, targeted rescan, bounded purge, and final verification. It SHALL stop at the first stage that fails and SHALL report which stages completed.

#### Scenario: Preflight finds an inconsistent release
- **WHEN** the preflight reconciliation reports the release as already inconsistent or not found
- **THEN** no later stage runs, nothing is moved or deleted, and the run exits with a failure status naming the preflight finding

#### Scenario: Stage fails midway
- **WHEN** the beets removal succeeds for the lossless database but fails for the lossy one
- **THEN** the files are not moved, the run stops, and the report states that the lossless rows were removed and the lossy ones were not

### Requirement: Files are moved to trash, never unlinked
The removal SHALL move the release folders into a trash area inside the shared music volume, preserving the release path and a run timestamp, and SHALL leave the trashed content readable for manual recovery. Permanently deleting trashed content SHALL require an explicit operator action outside the removal run.

#### Scenario: Successful removal keeps a copy
- **WHEN** a release is removed successfully
- **THEN** the trash area contains the lossless folder and the lossy folder under a path that identifies the release and the run

#### Scenario: Trash area already holds that release
- **WHEN** the run timestamp already exists for the same release
- **THEN** the run stops instead of overwriting the previously trashed copy

#### Scenario: Trash is outside every library root
- **WHEN** the release has been moved to trash
- **THEN** neither library scan nor the doctor considers the trashed files part of the library

### Requirement: Beets rows are removed by album identity
The removal SHALL delete the release's rows from both beets databases by album identity, and SHALL NOT delete rows by name, path, or query. It SHALL refuse when the album identity is missing or ambiguous, or when the two databases disagree about which album holds the release.

#### Scenario: Album identity known in both databases
- **WHEN** the release is identified by one album in each database
- **THEN** both albums and their items are removed, and the previous state of each database is preserved as a restorable copy

#### Scenario: One database does not hold the release
- **WHEN** the lossy database has no album for the release while the lossless one does
- **THEN** the run reports the asymmetry, removes only what exists, and does not fail the whole sequence

#### Scenario: Ambiguous identity
- **WHEN** more than one album in a database matches the release
- **THEN** the run stops before deleting anything and lists the candidate albums

### Requirement: Purge is bounded by a difference of inventory
Before purging, the removal SHALL capture the set of files Navidrome reports as missing and, after the targeted rescan, SHALL purge only when both that baseline and the post-rescan set are subsets of the files belonging to the removed release. Because the purge is library-wide, any unrelated entry in either set SHALL abort the run and leave the rows in place.

#### Scenario: Only the removed release became missing
- **WHEN** the baseline missing set is empty and after the rescan it contains exactly the removed release's tracks
- **THEN** the purge proceeds and the missing set returns to the baseline

#### Scenario: Baseline already holds an unrelated missing file
- **WHEN** the baseline contains a file that does not belong to the removed release
- **THEN** no purge happens, the run exits with a failure status, and the unrelated entry is named as the reason

#### Scenario: An unrelated file became missing during the run
- **WHEN** the post-rescan missing set contains any file that does not belong to the removed release
- **THEN** no purge happens, the run exits with a failure status, and the surplus entries are listed

#### Scenario: Purge leaves the policy unchanged
- **WHEN** a purge runs
- **THEN** the persistent configuration still reports the purge policy as "never" afterwards, and the purge applied only to the run that requested it

### Requirement: No irreversible stage without a fresh snapshot
The removal SHALL obtain a new Navidrome database snapshot and verify it is readable and complete before the first stage that can lose data. If the snapshot fails, the removal SHALL stop.

#### Scenario: Snapshot succeeds
- **WHEN** the snapshot is created and verified
- **THEN** the run reports the snapshot location and continues

#### Scenario: Snapshot fails
- **WHEN** the snapshot cannot be created or fails verification
- **THEN** no files are moved and no rows are removed, and the run exits with a failure status

### Requirement: Dry run touches nothing
The removal SHALL support a dry run that prints every intended action — the albums and rows to delete, the folders to move, the commands to run — and performs none of them.

#### Scenario: Dry run on a healthy release
- **WHEN** a dry run is requested for a release present in every store
- **THEN** the report lists the two album identities, the folder moves, and the scan and purge commands, and every store is byte-identical afterwards

### Requirement: Verification closes the loop
After a successful removal the run SHALL verify that the release is absent from all five views and that the Navidrome missing set is back to its baseline, and SHALL report the outcome without requiring a second command.

#### Scenario: Removal verified
- **WHEN** every stage completed
- **THEN** the final report states that the release is gone from the trees, both databases, and the Navidrome view, and that the missing set matches the baseline

#### Scenario: Leftovers survive
- **WHEN** the release still appears in some view after the final sweep
- **THEN** the run exits with a failure status and names the view that still holds it
