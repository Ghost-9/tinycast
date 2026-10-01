# iCloud Sync

Opt-in sync across the Macs signed in to one iCloud account, through CloudKit's `CKSyncEngine` on the
private database. It is switched on in **Settings → iCloud Sync**, and each category has its own switch:
**Settings**, **Shortcuts**, **Launcher** and **Window Management**. The feature lives in
`Features/Sync/`.

## Invariants

- **Only a build signed for the container syncs.** `CloudKitEntitlement` reads the container list from
  the signature before any `CKContainer` exists, because naming one the build isn't signed for traps.
  Debug and self-signed builds show the pane with its switch disabled. Signing is in
  [signing.md](../signing.md#icloud).
- **Every user field goes in `encryptedValues`.** The record name is the only plaintext, and a key
  that could say something (an entry ID, a file name) is digested before it becomes one.
- **A capability grant never syncs.** The setting kind carries only `SettingsFileKey`s, and a consent
  flag never has one, so no Mac can switch on snippets, extensions, calendar access or the like on
  another. The sync switches themselves are excluded from backups and from settings.json.
- **`SyncSettingsCoverage` decides every `SettingsFileKey`.** A key syncs unless it is `local` (it names
  a folder, an app or an input source on this Mac) or `carriedByRecords` (a kind carries its items one
  by one). `sync-test` checks the tables.
- **A record this Mac can't take is held, never deleted.** Two examples: a shortcut for an app this Mac
  lacks, and one whose chord is taken here. Each stays in the ledger with its payload and is retried
  after every fetch, local change and app scan. A local prune works the same way: an uninstalled app's
  binding is held, not deleted, so a missing app on one Mac costs no other Mac anything.
- **An applied record is never echoed back.** After an apply, the ledger records the store's own
  re-read, not the incoming payload, so a store that normalizes a value doesn't send it straight back.
- **`SyncRecordKind.category` and `CloudSyncSchema` are exhaustive switches.** A new kind fails to
  build until it names its category and its binding.
- **One container per channel**: `iCloud.<bundle id>`, keyed like every other store, so Beta and
  stable never share data.
- **Turning sync or a category off deletes nothing**, on this Mac or in iCloud. It forgets what this
  Mac had agreed with iCloud, so turning it back on starts fresh.

## Layout

| File | Role |
| --- | --- |
| `Model/SyncCategory.swift` | The pane's switches and the descriptor each one names |
| `Model/SyncRecordKind.swift` | Every record kind, its category, and its CloudKit-safe record name |
| `Model/SyncBinding.swift` | One kind bound to its store: `read`, `write`, `remove`, `isAvailable` |
| `Model/SyncLedger.swift` | What this Mac and iCloud agreed on; the diff that decides sends, deletes and holds |
| `Model/SyncMergePolicy.swift` | Which side wins a record both changed |
| `Model/SyncSettingsCoverage.swift` | Which settings.json keys sync, and why the rest don't |
| `Model/SyncDevice.swift` | A Mac in the list, and when it republishes |
| `Service/CloudSyncManager.swift` | The engine's lifecycle and delegate; the only type that talks to CloudKit |
| `Service/CloudSyncRecords.swift` | `CKRecord` in and out, all in `encryptedValues` |
| `Service/CloudKitEntitlement.swift` | The signature check that gates every `CKContainer` |
| `Service/CloudSyncState.swift` | What the pane shows: availability, times, Macs, held count |
| `Service/ShortcutSyncBinding.swift` | Shortcuts as records; a snippet's key names its file, not its path |
| `CloudSyncSchema.swift` | Each kind's binding to its store |
| `UI/CloudSyncCoordinator.swift` | The pane's actions and every sync dialog |
| `Settings/CloudSyncSettingsView.swift` | The pane |

## What syncs

| Category | One record per | Stored as |
| --- | --- | --- |
| Settings | synced `SettingsFileKey` | settings.json's own spelling of that value |
| Shortcuts | bound `HotKeyAction` | its `HotKeyBinding` |
| Launcher | alias and hidden item; favorites, hidden kinds and pinned emoji as one list each | JSON |
| Window Management | custom size, layout and room | settings.json's spelling, without runtime state or the shortcut |

An ordered list syncs whole, because merging two orders item by item produces neither. Everything else
syncs item by item, so edits to different items on two Macs both survive.

These **never** sync: consent flags; `notes.folder`, `snippets.folder`, the input source and the
meeting browser, each of which names something on one Mac; the palette's position; a room's window
numbers and when it was last entered; clipboard history; launcher learning; AI chat history; and
anything in the Keychain.

## How it works

**Local → iCloud.** The manager reads every enabled binding inside `withObservationTracking`, so any
store change schedules a pass 2 s later. `SyncLedger.reconcile` diffs what the stores hold against what
was agreed and returns the records to send and delete. Only changed payloads are kept in memory. The
engine pulls them through `nextRecordZoneChangeBatch`, and a confirmed save records the digest of the
payload that was sent.

**iCloud → local.** A fetched record goes through `SyncMergePolicy`, then through its binding's
`write`. A write that returns false holds the record. A remote delete removes the item, unless this Mac
has an edit that hasn't been sent yet. In that case the edit survives and goes back up as a new record.

**Conflicts.** The newer edit wins, by the `editedAt` each Mac stamps when it notices a change. A tie
goes to the server, because every Mac agrees on that result. A `serverRecordChanged` failure goes
through the same policy.

**First contact.** When a Mac with no ledger finds the zone already in iCloud, one dialog asks
**Use iCloud's** or **Keep This Mac's**. The answer decides only keys that both sides hold and have
never agreed on. Everything else is merged, and nothing is deleted. Cancel turns sync back off.

**Deletes** stay in `pendingDeletes` until confirmed, and are queued again on every engine start, so a
reset engine state can't lose one.

**Macs.** Each Mac publishes a `SyncDevice` record when it starts and on wake. It republishes only when
its record is an hour old, or when its name or version changed. **Remove** deletes another Mac's record.
If that Mac still syncs, it publishes the record again.

**Resets.** If another Mac deletes the zone (**Delete iCloud Data**), this Mac stops syncing and says
so in a HUD. If the zone is lost to an encrypted-data reset, this Mac uploads everything again. If the
iCloud account changes, the ledger is cleared and the engine restarts.

**Fetching** happens on push (`aps-environment` and `registerForRemoteNotifications`), on launch, on
wake, when the pane opens, and on **Sync Now**. There is no polling timer. Add one only if measurement
shows that pushes are missed.

## The ledger

`cloud-sync.plist` in Application Support is a binary plist holding the engine's state serialization,
one entry per record, pending deletes and the Mac list. It is written off-main at most once a second,
and synchronously at quit.

## Schema

`Scripts/cloudkit/schema.ckdb` declares the two record types, `SyncItem` and `SyncDevice`, with every
field `ENCRYPTED`. `Scripts/cloudkit/deploy-schema.sh <bundle-id>` imports it into a container's
Development environment. The CloudKit Console's **Deploy Schema Changes** then promotes it to
Production, once per channel.

A breaking change to a payload moves sync to a new zone name. It is never migrated: older builds keep
syncing among themselves in the old zone.

## Adding a kind

1. Add a `SyncRecordKind` case and its category. Add a `SyncCategory` too if no existing switch fits.
2. Bind the kind in `CloudSyncSchema`. Return false from `write` for anything this Mac can't take yet.
   Return false from `isAvailable` for a record that is missing because of something this Mac lacks.
3. Add the record type's fields to `schema.ckdb` if the kind needs new ones, then deploy it.
4. Cover the new kind's rules in `sync-test`.
