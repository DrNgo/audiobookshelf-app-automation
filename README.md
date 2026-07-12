# audiobookshelf-app TestFlight pipeline

Builds the iOS app from [DrNgo/audiobookshelf-app](https://github.com/DrNgo/audiobookshelf-app) — the `master` branch of my fork — and uploads it to a private TestFlight, automatically, every time that branch advances. `.upstream-version` pins the exact commit SHA currently shipped.

## How it works

1. **`check-upstream-release.yml`** runs every 24 hours and on-demand. It compares the fork branch's HEAD commit SHA against the SHA pinned in `.upstream-version`. If they differ, it opens a PR bumping `.upstream-version` (it does **not** merge it).
2. **`deploy-testflight.yml`** builds the PR as a gate: it checks out the fork at the pinned commit, runs `npm ci && npm run generate && npx cap sync ios && pod install`, then runs the `ios build` fastlane lane to sign with Match and build with `gym`. The resulting `.ipa` is stashed as a build artifact. **A broken commit fails here and never merges** — `main` stays on the last known-good commit.
3. When the build is green, the same job merges the bump PR (using `RELEASE_BOT_TOKEN`, so the merge push can trigger the next step). The merge lands a push on `main` touching `.upstream-version`.
4. The `deploy` job triggers on that push and **reuses the artifact built in step 2** — it downloads the `.ipa` and runs only the `ios upload` lane (`pilot`) instead of rebuilding. If no matching artifact is found, or the upload is rejected (e.g. a duplicate build number), it falls back to a full `ios beta` build.

The artifact is matched by a content hash of `.upstream-version`, `fastlane/**`, `scripts/prepare-upstream.sh`, and the deploy workflow, so an artifact is only reused when it corresponds exactly to what landed on `main`.

You can also dispatch `deploy-testflight.yml` manually from the Actions tab, and it runs on a bimonthly schedule (see [TestFlight build expiry](#testflight-build-expiry)); both of those always do a full rebuild rather than reusing an artifact.

**`rotate-certificates.yml`** keeps signing material valid without any manual intervention. It runs the `certificates` fastlane lane on a CI runner — monthly on a `cron: "0 10 5 * *"` schedule and on-demand via `workflow_dispatch`. Match only regenerates expired or missing certs and profiles, so the scheduled run is a no-op while the current material is valid; it effectively self-heals within a month of expiry. See [Secret and certificate rotation](#secret-and-certificate-rotation) for details.

**Dependabot** keeps GitHub Actions and Ruby gems fresh. Minor and patch updates auto-merge via `.github/workflows/auto-merge-dependabot.yml`; major updates wait for manual review. For auto-merge to work, enable **Settings → General → Pull Requests → Allow auto-merge** on the repository.

## Prerequisites

- Apple Developer Program membership.
- Two empty repositories on your GitHub account:
  - This one (public is fine — nothing identifying is committed).
  - A second **private** repository for [fastlane Match](https://docs.fastlane.tools/actions/match/) certificates and provisioning profiles.
- A bundle identifier registered in your Apple Developer account.
- An App Store Connect record for that bundle ID, with TestFlight enabled.

## Required GitHub Actions secrets

| Secret                          | Where to get it                                                                                                                                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `RELEASE_BOT_TOKEN`             | Fine-grained personal access token with **Contents: read/write** and **Pull requests: read/write** on this repo. Required so the build gate can merge bump PRs and have the merge trigger the deploy workflow (the default `GITHUB_TOKEN` cannot trigger other workflows). The fork it reads (`DrNgo/audiobookshelf-app`) is public, so no extra scope is needed to poll its commits. |
| `DEVELOPER_APP_IDENTIFIER`      | Your reverse-DNS bundle identifier (e.g. `com.example.audiobookshelf`).                                                                                                                                                        |
| `DEVELOPER_PORTAL_TEAM_ID`      | 10-character team ID from [developer.apple.com → Account → Membership](https://developer.apple.com/account).                                                                                                                   |
| `APPLE_KEY_ID`                  | App Store Connect API key ID. Create at [App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys](https://appstoreconnect.apple.com/access/api). Use **Admin** or **App Manager** role.        |
| `APPLE_ISSUER_ID`               | Issuer ID from the same page.                                                                                                                                                                                                  |
| `APPLE_KEY_CONTENT`             | Base64-encoded contents of the `.p8` private key file. Generate with `base64 -i ~/Downloads/AuthKey_<KEYID>.p8` and paste the resulting single-line string verbatim.                                                           |
| `MATCH_GIT_URL`                 | HTTPS clone URL of your private Match repository (e.g. `https://github.com/you/match-certificates`).                                                                                                                           |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `username:token` string for that repo, where `token` is a fine-grained PAT with **Contents: read/write** on the Match repo. The Fastfile base64-encodes this before passing to Match.                                          |
| `MATCH_PASSWORD`                | Passphrase used to encrypt the Match repository contents. Pick any long random string the first time you run Match; remember it.                                                                                               |
| `TEMP_KEYCHAIN_PASSWORD`        | Any long random string. Used as the password for the ephemeral keychain created on the CI runner.                                                                                                                              |

### Optional overrides

These are **not** required — the pipeline derives sensible defaults from `DEVELOPER_APP_IDENTIFIER`. Set them only if your portal identifiers differ from the defaults (see [Widget extension & App Group](#widget-extension--app-group)).

| Secret / variable | Default | Purpose |
| --- | --- | --- |
| `DEVELOPER_WIDGET_APP_IDENTIFIER` | `<DEVELOPER_APP_IDENTIFIER>.widget` | Bundle id of the widget app-extension. Apple requires it to be a child of the host app id. |
| `DEVELOPER_APP_GROUP` | `group.<DEVELOPER_APP_IDENTIFIER>` | Shared App Group id the app and widget use to exchange the server URL + token. |

## First-run setup

Everything runs on GitHub — all setup is done through the repository settings and the Actions tab.

1. **Add the secrets.** Under **Settings → Secrets and variables → Actions**, add every secret from the [Required GitHub Actions secrets](#required-github-actions-secrets) table. Two gotchas:
   - Strip any leading or trailing whitespace from each value — an extra space in `DEVELOPER_APP_IDENTIFIER` makes Match fail with `Could not find App ID`.
   - `APPLE_KEY_CONTENT` must be the base64 of the **same** `.p8` whose ID is in `APPLE_KEY_ID`. Generate with `base64 -i ~/Downloads/AuthKey_<KEYID>.p8` and paste the single-line output. The `.p8` is downloadable only once at key-creation time — if you've lost it, revoke the key and create a new one.
2. **Seed the Match repo.** Run the **Rotate certificates** workflow from the Actions tab (Run workflow → `workflow_dispatch`). Because the private Match repo starts empty, the `certificates` lane generates a fresh App Store distribution cert + provisioning profile and pushes them encrypted. The lane authenticates with the App Store Connect API key (no Apple ID prompt) and uses an ephemeral keychain on the runner; the resulting profile is named `match AppStore <bundle-id>`.
3. **Confirm end-to-end.** Trigger the **Deploy to TestFlight** workflow manually to build the currently pinned `.upstream-version` and upload it to TestFlight.

Once step 3 succeeds, the pipeline is fully autonomous: upstream releases deploy on their own, builds refresh on schedule, and signing material self-rotates.

## Widget extension & App Group

Newer upstream commits embed an **`AudiobookshelfWidget`** app-extension target (the home/lock-screen widget). It runs as a separate process and talks to the app through a shared **App Group** (the app writes the server URL + access token; the widget reads them). An App Store build must therefore sign the extension in addition to the app.

The Fastfile handles this automatically and **only when the pinned upstream actually contains the target** — older pins without the widget build exactly as before (the widget signing is skipped, logged as `AudiobookshelfWidget target absent in this upstream pin`). When the target is present, the build:

- provisions and signs the widget under its own bundle id — `<DEVELOPER_APP_IDENTIFIER>.widget` by default (Apple requires an extension id to be a child of the host app id), or `DEVELOPER_WIDGET_APP_IDENTIFIER` if set;
- rewrites the shared App Group id in the checkout from the upstream default (`group.com.audiobookshelf.app`) to **`group.<DEVELOPER_APP_IDENTIFIER>`** (or `DEVELOPER_APP_GROUP`). App Group ids are globally unique across Apple, so the upstream default can't be reused under a different team. The rewrite touches both entitlements files **and** the Swift constant that reads the container — all must agree, and the build fails loudly if the upstream string ever moves;
- stamps the widget with the same marketing version + build number as the app (App Store Connect rejects an extension whose version doesn't match its host);
- exports both provisioning profiles.

### One-time portal setup (required before the first widget-containing build)

Match and the App Store Connect API key create certs/profiles but **cannot create or associate an App Group** — the public API has no App Group CRUD, and the legacy portal path needs an Apple ID session. So do this once, manually, in the [Apple Developer portal](https://developer.apple.com/account/resources):

1. **Register the widget App ID** `<DEVELOPER_APP_IDENTIFIER>.widget` (Identifiers → App IDs). Match will also create it on first run, but registering it up front is cleaner.
2. **Create the App Group** `group.<DEVELOPER_APP_IDENTIFIER>` (Identifiers → App Groups).
3. **Enable the App Groups capability** on **both** App IDs (the app and the `.widget`) and **associate** the group to each.
4. **Regenerate profiles** so they carry the entitlement: run the **Rotate certificates** workflow (or `fastlane match appstore --force`). It provisions both App IDs.

If this isn't done, the first widget-containing build fails at signing/export with a provisioning **entitlement mismatch** (the profile lacks the App Group), or `match` errors that it can't find the widget App ID. Once done, it's stable — the group and capability don't change between releases.

## Secret and certificate rotation

Nothing in this stack emails you on expiry — set calendar reminders when you create each one, and note each expiry date wherever you keep the secret values.

| Secret / artifact | Lifetime | Failure signature when expired |
| --- | --- | --- |
| `RELEASE_BOT_TOKEN` | as set on the fine-grained PAT (1 year recommended) | **Check upstream commit** workflow fails at `gh api .../commits` (or the bump `git push`) with a 401 |
| `MATCH_GIT_BASIC_AUTHORIZATION` | as set on the Match PAT (1 year recommended) | Deploy fails inside `match` with a 401 cloning the certs repo |
| `APPLE_KEY_*` (App Store Connect API key) | no automatic expiry; only revoked manually | Deploy fails with `Authentication credentials are missing or invalid` |
| App Store distribution certificate | 1 year (Apple) | Build fails during code signing — `match` reports no valid certificate |
| Provisioning profile (`match AppStore <bundle-id>`) | 1 year (Apple) | Same as the certificate |

To rotate certificate / profile, run the **Rotate certificates** workflow from the Actions tab (`workflow_dispatch`) — it runs the `certificates` lane on a CI runner using the same secrets as the deploy workflow, and Match detects the expired material in the certs repo and regenerates everything in-place. The workflow also runs monthly on a `cron: "0 10 5 * *"` schedule; because Match only regenerates missing or expired material, the scheduled run is a no-op while the cert is still valid, so it effectively self-heals within a month of expiry.

To rotate a PAT, regenerate it on GitHub and replace the value under **Settings → Secrets and variables → Actions**. To rotate the API key, revoke and recreate it in App Store Connect, then update the `APPLE_KEY_*` secrets as in step 1 of first-run setup. Neither can be fully automated: GitHub fine-grained PATs and App Store Connect API keys have no creation API, so minting the new credential is always a manual step.

## TestFlight build expiry

Apple expires TestFlight builds 90 days after upload. The **Deploy to TestFlight** workflow runs on a `cron: "0 10 1 */2 *"` schedule (every two months, on the 1st at 10:00 UTC) to rebuild the currently pinned `.upstream-version` and refresh the expiry — even when the fork branch hasn't advanced.

## Bumping the pinned commit manually

Normally the **Check upstream commit** workflow does this for you when `master` advances. To force a specific commit (or to build a different branch of the fork), pin it directly:

```sh
# a full commit SHA on the fork...
echo 185cba16eb122b40e8537a7bf475632680d6fb94 > .upstream-version
# ...or a branch/tag name, which prepare-upstream.sh also accepts:
# echo fix/download-reliability > .upstream-version
git add .upstream-version
git commit -m "pin audiobookshelf-app to <ref>"
git push
```

The deploy workflow will run on push to `main`. Note the daily poll compares against `master`'s HEAD, so if you pin a one-off commit the next poll will still try to bump you back onto `master`.
