# iCloud Sync

Opt-in sync across the Macs signed in to one iCloud account, through CloudKit's `CKSyncEngine` on the
private database. It is switched on in **Settings → iCloud Sync**, where each category has its own
switch, plus one for **Include API keys and tokens**. The feature lives in `Features/Sync/`.
Extensions' part of it lives in `Features/Extensions/`.

## Invariants

- **Only a build signed for the container syncs.** `CloudKitEntitlement` reads the container list from
  the signature before any `CKContainer` exists, because naming one the build isn't signed for traps.
  Debug and self-signed builds show the pane with its switch disabled. Signing is in
  [signing.md](../signing.md#icloud).
- **Every user field goes in `encryptedValues`.** The record name is the only plaintext, and a key
  that could say something (an entry ID, a file name) is digested before it becomes one.
- **A capability grant never syncs.** Consent flags have no `SettingsFileKey`, so no Mac can switch on
  snippets, extensions, calendar access or the like on another. An MCP server's trust is reset to
  **Ask** on the way out. The sync switches themselves are excluded from backups and from
  settings.json.
- **A category that runs code asks first.** Custom Commands, MCP Servers and Extensions each confirm
  before they switch on (`SyncCategory.Descriptor.consent`), and none is on by default.
- **Secrets never touch the ledger.** API keys, MCP headers and variables, and extension passwords
  travel in a record's `secrets` field, only while **Include API keys and tokens** is on. The ledger
  on disk keeps bodies, never secrets. A Mac with the switch off neither sends nor stores them.
- **`SyncSettingsCoverage` decides every `SettingsFileKey`.** A key syncs unless it is `local` (it names
  a folder, an app or an input source on this Mac) or `carriedByRecords` (a kind carries its items one
  by one). `sync-test` checks the tables.
- **A record this Mac can't take is held, never deleted.** Examples: a shortcut for an app this Mac
  lacks, an extension no registry here offers, or a name already taken here. Each stays in the ledger
  and is retried after every fetch, local change and app scan. A record missing because this Mac lacks
  what it names (`isAvailable` false) is held too, so a missing app costs no other Mac anything.
- **A store that hasn't loaded sits the pass out.** Its binding's `read` returns nil, so an empty list
  is never mistaken for everything having been deleted. The extension set is one example: it is empty
  until its first scan.
- **Text a person wrote is never lost to a conflict.** Notes and snippets keep both sides
  (`keepCopy`): the other version is saved beside the original as "Title (conflicted copy).md". A
  note's open, unsaved draft is never replaced, because `NotesStore.acceptRemote` refuses and the
  binding keeps the copy instead.
- **An applied record is never echoed back.** After an apply, the ledger records the store's own
  re-read, not the incoming payload.
- **A moved folder is a new collection.** When the notes or snippets folder changes, the kind is
  forgotten and fetched again. The new folder merges with iCloud, and nothing is deleted.
- **`SyncRecordKind.category` and `CloudSyncSchema` are exhaustive switches.** A new kind fails to
  build until it names its category and its binding.
- **One container per channel**: `iCloud.<bundle id>`, so Beta and stable never share data.
- **Turning sync or a category off deletes nothing**, on this Mac or in iCloud. It forgets what this
  Mac had agreed with iCloud, so turning it back on starts fresh.

## Layout

| File | Role |
| --- | --- |
| `Model/SyncCategory.swift` | The pane's switches: label, detail and, for code, the consent text |
| `Model/SyncRecordKind.swift` | Every record kind, its category, whether it is a file, and its record name |
| `Model/SyncPayload.swift` | A record's body and secrets, and the digest that covers both |
| `Model/SyncBinding.swift` | One kind bound to its store: `observe`, `read`, `write`, `remove`, and optionally `scope` and `keepCopy` |
| `Model/SyncLedger.swift` | What this Mac and iCloud agreed on; the diff that decides sends, deletes and holds |
| `Model/SyncMergePolicy.swift` | Which side wins, or that both are kept |
| `Model/SyncSettingsCoverage.swift` | Which settings.json keys sync, and why the rest don't |
| `Model/SyncFileName.swift` | Which file names a folder kind accepts, and where a conflict copy goes |
| `Model/SyncDevice.swift` | A Mac in the list, and when it republishes |
| `Service/CloudSyncManager.swift` | The engine's lifecycle and delegate, and the serial chain every pass runs on |
| `Service/CloudSyncRecords.swift` | `CKRecord` in and out, all in `encryptedValues` |
| `Service/CloudKitEntitlement.swift` | The signature check that gates every `CKContainer` |
| `Service/CloudSyncState.swift` | What the pane shows: availability, times, Macs, held count |
| `Service/FolderSyncReader.swift` | A folder's `.md` files, re-read only when one changes; writes, copies, trashes |
| `Service/ShortcutSyncBinding.swift` | Shortcuts as records; a snippet's key names its file, not its path |
| `CloudSyncSchema.swift` | Each kind's binding to its store |
| `UI/CloudSyncCoordinator.swift` | The pane's actions and every sync dialog |
| `Settings/CloudSyncSettingsView.swift` | The pane |
| `Extensions/Service/ExtensionSyncBinding.swift` | Installed extensions and their preferences |

## What syncs

| Category | One record per | Notes |
| --- | --- | --- |
| Settings | synced `SettingsFileKey` | settings.json's own spelling of the value |
| Shortcuts | bound `HotKeyAction` | held while its app or item is missing, or its chord is taken |
| Launcher | alias and hidden item | favorites, hidden kinds and pinned emoji are one list each |
| Quicklinks | quicklink | |
| Snippets | `.md` file in the snippets folder | written to the folder; the store's watcher reloads |
| Notes | `.md` file in the notes folder | written through `NotesStore`; a remote delete goes to the Trash |
| Window Management | custom size, layout, room | settings.json's spelling, without runtime state or the shortcut |
| AI | API connection, custom quick action | a connection's key is a secret |
| Custom Commands | command | asks first |
| MCP Servers | server | asks first; header and variables are secrets; trust stays local |
| Extensions | installed extension | asks first; installs from this Mac's registries, in the background |

An ordered list syncs whole, because merging two orders item by item produces neither. Everything else
syncs item by item, so edits to different items on two Macs both survive.

These **never** sync:
- consent flags;
- the notes and snippets folder paths, the input source and the meeting browser;
- the palette's position;
- a room's window numbers and when it was last entered;
- an MCP server's trust and OAuth session;
- an extension's local storage, cache, OAuth tokens and path preferences;
- installed AI tools and the default model, which depend on what each Mac has;
- clipboard history, launcher learning and AI chats.

## How it works

**One pass at a time.** Every pass that reads or writes the ledger joins a serial chain on the
manager: a local reconcile, each engine event, retrying held records, and a category change. Bindings
are async, so file and Keychain work runs off the main actor. The chain is what keeps one pass from
landing in the middle of another at a suspension point. `syncNow` and `deleteAllData` stay off the
chain, because the events they trigger join it and would otherwise wait on them forever.

**Local → iCloud.** Under `withObservationTracking`, each binding's `observe` touches what its `read`
depends on, so any store change schedules a pass 2 s later. `SyncLedger.reconcile` diffs what the
stores hold against what was agreed and returns the records to send and delete. Only changed payloads
are kept in memory. The engine pulls them through `nextRecordZoneChangeBatch`, and a confirmed save
records the digest of the payload that was sent.

**iCloud → local.** A fetched record goes through `SyncMergePolicy`, then through its binding's
`write`. A write that returns false holds the record. A remote delete removes the item, unless this Mac
has an edit that hasn't been sent yet. In that case the edit survives and goes back up as a new record.

**Conflicts.** For notes and snippets, both sides are kept. For everything else, the newer edit wins,
by the `editedAt` each Mac stamps when it notices a change; a tie goes to the server. The same edit
made on both sides is no conflict at all. A `serverRecordChanged` failure goes through the same policy.

**First contact.** When a Mac with no ledger finds the zone already in iCloud, one dialog asks
**Use iCloud's** or **Keep This Mac's**. The answer decides only keys that both sides hold and have
never agreed on. Everything else is merged, and nothing is deleted. Cancel turns sync back off.

**Extensions** install in the background, because a source build can take minutes. The record is held
until the install lands, and the extension set changing retries it. An extension that no registry
enabled on this Mac offers, or that fails to build, is held and is not retried this session.

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
shows that pushes are missed. Extension preferences are not observable, so a change to one rides along
with the next pass.

## The ledger

`cloud-sync.plist` in Application Support is a binary plist. It holds:
- the engine's state serialization;
- one entry per record;
- pending deletes;
- each folder kind's scope;
- the Mac list.

It never holds a secret, and never holds a note's or snippet's text. It is written off-main at most
once a second, and synchronously at quit.

## Schema

`Scripts/cloudkit/schema.ckdb` declares the two record types, `SyncItem` and `SyncDevice`, with every
field `ENCRYPTED`. `Scripts/cloudkit/deploy-schema.sh <bundle-id>` imports it into a container's
Development environment. The CloudKit Console's **Deploy Schema Changes** then promotes it to
Production, once per channel.

A breaking change to a payload moves sync to a new zone name. It is never migrated: older builds keep
syncing among themselves in the old zone.

## Adding a kind

1. Add a `SyncRecordKind` case and its category. Add a `SyncCategory` too if no existing switch fits,
   with consent text if it runs code here.
2. Bind the kind in `CloudSyncSchema`, or in its own feature when a non-negotiable says so (as for
   extensions):
   - Return nil from `read` until the store has loaded.
   - Return false from `write` for anything this Mac can't take yet.
   - Return false from `isAvailable` for a record missing because of something this Mac lacks.
   - Put keys and tokens in `secrets`, never in the body.
3. Add the record type's fields to `schema.ckdb` if the kind needs new ones, then deploy it.
4. Cover the new kind's rules in `sync-test`.
