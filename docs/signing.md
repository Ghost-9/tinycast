# Signing

Local builds are signed with a **stable self-signed identity** called `Tinycast Self-Signed`. Keeping
the _same_ identity on every build is what makes macOS remember the Accessibility permission across
rebuilds — ad-hoc signing changes every build and macOS forgets the grant.

Releases are signed with the team's **Developer ID** and embed a provisioning profile, because the
entitlements [iCloud sync](features/icloud-sync.md) needs are restricted and only a profile grants
them. How that is wired is [below](#icloud); why the switch was staged is in
[the Developer ID migration](#the-developer-id-migration).

You create the self-signed identity **once**; the Xcode project signs every local build with it.

## 1. Create the `Tinycast Self-Signed` identity (once)

Run these in a terminal. They generate a self-signed code-signing certificate and import it into your
login keychain:

```sh
# Generate a self-signed code-signing cert (10-year, codeSigning use).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /tmp/tc-key.pem -out /tmp/tc-cert.pem \
  -subj "/CN=Tinycast Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle it as a .p12 (the non-empty password keeps `security import` happy).
openssl pkcs12 -export -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Tinycast Self-Signed" -out /tmp/tc.p12 -passout pass:tinycast

# Import into the login keychain so codesign can use it without prompting.
security import /tmp/tc.p12 -k ~/Library/Keychains/login.keychain-db \
  -P tinycast -A -T /usr/bin/codesign

rm -f /tmp/tc-key.pem /tmp/tc-cert.pem /tmp/tc.p12
```

Verify it's there:

```sh
security find-identity -p codesigning | grep "Tinycast Self-Signed"
```

Now local builds (Xcode, VS Code F5, `xcodebuild`) sign with it, and you grant Accessibility once.

## 2. Set the release secrets

The release workflow signs with the **Developer ID Application** identity and one provisioning profile
per channel. `Scripts/import-signing.sh` installs both on the runner and fails the job, naming the
secret, if one is missing. Four secrets:

| Secret | Holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application identity, exported as `.p12` and base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | That export's password |
| `PROFILE_STABLE_BASE64` | The Developer ID provisioning profile for `com.tinycast.app`, base64-encoded |
| `PROFILE_BETA_BASE64` | The same for `com.tinycast.app.beta` |

```sh
P12_PASSWORD="$(openssl rand -base64 24)"
# Export "Developer ID Application: …" from Keychain Access as /tmp/devid.p12 with that password.
gh secret set DEVELOPER_ID_P12_BASE64   --repo abue-ammar/tinycast --body "$(base64 -i /tmp/devid.p12)"
gh secret set DEVELOPER_ID_P12_PASSWORD --repo abue-ammar/tinycast --body "$P12_PASSWORD"
gh secret set PROFILE_STABLE_BASE64 --repo abue-ammar/tinycast --body "$(base64 -i Tinycast.provisionprofile)"
gh secret set PROFILE_BETA_BASE64   --repo abue-ammar/tinycast --body "$(base64 -i TinycastBeta.provisionprofile)"
rm -f /tmp/devid.p12   # holds the private key — delete it
```

A profile expires and is regenerated in the portal; set its secret again when it does. Renewing the
certificate strands nobody, because the updater's requirement pins the team, not the certificate.

## Hardened runtime

**Release only**, on both targets: `ENABLE_HARDENED_RUNTIME: YES`, which notarization requires. Debug
must stay without it — hardened runtime turns on library validation, and Xcode's
`Tinycast Dev.debug.dylib` is refused at launch because a self-signed identity carries no Team ID for
the loader to match. The flag is not part of the designated requirement, so turning it on costs no
Accessibility grant. Each entitlement in `Tinycast/Tinycast.entitlements` earns its place:

| Entitlement | Without it |
| --- | --- |
| `com.apple.security.cs.allow-jit` | JavaScriptCore cannot JIT, and every extension command runs on the interpreter |
| `com.apple.security.automation.apple-events` | Every Apple event is refused with `-1743` and no prompt — Get Info, the Finder selection an extension reads, and the System Events–driven system actions all die silently |
| `com.apple.security.device.camera` | The camera prompt never appears and access resolves as denied |
| `com.apple.security.personal-information.calendars` | `requestFullAccessToEvents()` returns `false` in milliseconds with no dialog, and Tinycast never appears under System Settings › Calendars |

**A usage string is not enough under the hardened runtime.** `tccd` checks the matching entitlement
*before* it prompts, and without it logs "requires entitlement … but it is missing" and denies on the
spot — no dialog, no error, status still `.notDetermined`. A grant saved before the hardened runtime
arrived keeps working, since `tccd` does not re-check it, which is why this surfaces only on fresh
installs. Adding a protected resource therefore means adding its usage string *and* its entitlement.

`RESOURCE_ENTITLEMENTS` in `Scripts/verify-signature.sh` maps every protected resource's usage string
to its entitlement, including resources Tinycast does not use. That grants nothing — only
`Tinycast.entitlements` does, and a row whose usage string `Info.plist` doesn't declare is skipped. It
is there so a future feature that adds the usage string but forgets the entitlement fails the release
instead of shipping a prompt that can never appear.

Nothing else is needed: the only `dlopen` is Apple's own IOBluetooth, so library validation is left
on, and `node`, `ray` and shell commands are separate processes it never reaches. Bluetooth has no
hardened-runtime entitlement.

`./Scripts/verify-signature.sh <path-to-.app>` asserts all of this — the runtime flag on the app *and*
on `Contents/Helpers/ClipboardTextHelper`, an intact nested seal, no `get-task-allow`, and an
entitlement for every usage string `Info.plist` declares. Both release jobs run it before packaging:
a nested binary missing the runtime flag is the most common notarization rejection, and a usage string
missing its entitlement ships a permission that can never be granted.

## The Developer ID migration

Releases now sign with Developer ID. The switch was staged: `BundleSignature` accepted a bundle signed
by the Tinycast team under Apple's Developer ID chain before any release was signed that way, because
the updater compares signatures before it installs, and the code that trusts the new identity had to
reach users *before* the first build carrying it. It still accepts the running app's own leaf, which
is the only thing a copy installed earlier knows how to check. The first Developer ID build has a new
designated requirement, so macOS asks every user for Accessibility once more.

The requirement pins the team rather than the certificate, so a Developer ID renewal strands nobody.
It deliberately omits the `notarized` keyword — that resolves a ticket through `syspolicyd` or the
network, and the updater verifies in a cache directory Gatekeeper has never assessed, so an offline
Mac would refuse a bundle the chain already proves is ours.

**The Developer ID identity stays a CI-only fact.** It is named on the release workflow's
`xcodebuild` line and nowhere else: `project.yml` keeps signing with
`Tinycast Self-Signed`, so a contributor keeps building with the one they created in §1 — same name,
their own key, never shared. Nothing about local development changes.

**Keep `Tinycast Self-Signed` in the login keychain after the switch.** It is the only way to ship a
build that a copy predating the migration could still install.

## iCloud

The restricted entitlements live in `Tinycast/TinycastCloud.entitlements`: `icloud-services`
(CloudKit), `icloud-container-identifiers` (`iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)`, so each channel gets
its own container), `icloud-container-environment` and `aps-environment`. A build that claims them
without a profile that grants them is killed at launch, before any UI, so `project.yml` leaves them out
by default and only overrides them for the app target:

| Setting | Default | Release CI |
| --- | --- | --- |
| `TINYCAST_ENTITLEMENTS` | `Tinycast/Tinycast.entitlements` | `Tinycast/TinycastCloud.entitlements` |
| `TINYCAST_PROVISIONING_PROFILE` | empty | the channel profile's UUID |
| `TINYCAST_CLOUD_ENVIRONMENT` / `TINYCAST_PUSH_ENVIRONMENT` | `Production` / `production` | the same |

These are per-target settings rather than overrides of `CODE_SIGN_ENTITLEMENTS`, because an override on
the `xcodebuild` line reaches every target. If it reached `ClipboardTextHelper`, the helper would claim
iCloud with no profile of its own and die on launch.

`TinycastCloud.entitlements` restates the base file. `verify-signature.sh` fails a build that is
missing any key from `Tinycast.entitlements`, and a build that claims iCloud without
`embedded.provisionprofile`.

Setting up a channel in the developer portal is a one-time job: enable iCloud (CloudKit) and Push
Notifications on its App ID, create the container `iCloud.<bundle id>`, generate a Developer ID
profile, and deploy the schema ([features/icloud-sync.md](features/icloud-sync.md#schema)). Local work
on sync uses a team-signed Dev build against the Development environment; see
[development.md](development.md#icloud-sync).

## Quarantine (separate from signing)

macOS quarantines anything downloaded from the internet, and Gatekeeper blocks an app that isn't
notarized — which releases are not yet — with an "unverified developer" warning. The Homebrew cask runs
`xattr -dr com.apple.quarantine` in `postflight`, so **brew users never touch it**. People who
download the DMG directly clear it once by hand.
