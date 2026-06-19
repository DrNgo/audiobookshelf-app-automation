# audiobookshelf-app TestFlight pipeline

Builds the iOS app from [advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app) and uploads it to a private TestFlight, automatically, every time upstream cuts a new release.

## How it works

1. **`check-upstream-release.yml`** runs every 24 hours and on-demand. It compares the upstream's latest release tag against `.upstream-version`. If they differ, it opens a PR bumping `.upstream-version` (it does **not** merge it).
2. **`deploy-testflight.yml`** builds the PR as a gate: it clones upstream at the new tag, runs `npm ci && npm run generate && npx cap sync ios && pod install`, then runs the `ios build` fastlane lane to sign with Match and build with `gym`. The resulting `.ipa` is stashed as a build artifact. **A broken upstream release fails here and never merges** — `main` stays on the last known-good version.
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
| `RELEASE_BOT_TOKEN`             | Fine-grained personal access token with **Contents: read/write** and **Pull requests: read/write** on this repo. Required so the build gate can merge bump PRs and have the merge trigger the deploy workflow (the default `GITHUB_TOKEN` cannot trigger other workflows). |
| `DEVELOPER_APP_IDENTIFIER`      | Your reverse-DNS bundle identifier (e.g. `com.example.audiobookshelf`).                                                                                                                                                        |
| `DEVELOPER_PORTAL_TEAM_ID`      | 10-character team ID from [developer.apple.com → Account → Membership](https://developer.apple.com/account).                                                                                                                   |
| `APPLE_KEY_ID`                  | App Store Connect API key ID. Create at [App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys](https://appstoreconnect.apple.com/access/api). Use **Admin** or **App Manager** role.        |
| `APPLE_ISSUER_ID`               | Issuer ID from the same page.                                                                                                                                                                                                  |
| `APPLE_KEY_CONTENT`             | Base64-encoded contents of the `.p8` private key file. Generate with `base64 -i ~/Downloads/AuthKey_<KEYID>.p8` and paste the resulting single-line string verbatim.                                                           |
| `MATCH_GIT_URL`                 | HTTPS clone URL of your private Match repository (e.g. `https://github.com/you/match-certificates`).                                                                                                                           |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `username:token` string for that repo, where `token` is a fine-grained PAT with **Contents: read/write** on the Match repo. The Fastfile base64-encodes this before passing to Match.                                          |
| `MATCH_PASSWORD`                | Passphrase used to encrypt the Match repository contents. Pick any long random string the first time you run Match; remember it.                                                                                               |
| `TEMP_KEYCHAIN_PASSWORD`        | Any long random string. Used as the password for the ephemeral keychain created on the CI runner.                                                                                                                              |

## First-run setup

Everything runs on GitHub — all setup is done through the repository settings and the Actions tab.

1. **Add the secrets.** Under **Settings → Secrets and variables → Actions**, add every secret from the [Required GitHub Actions secrets](#required-github-actions-secrets) table. Two gotchas:
   - Strip any leading or trailing whitespace from each value — an extra space in `DEVELOPER_APP_IDENTIFIER` makes Match fail with `Could not find App ID`.
   - `APPLE_KEY_CONTENT` must be the base64 of the **same** `.p8` whose ID is in `APPLE_KEY_ID`. Generate with `base64 -i ~/Downloads/AuthKey_<KEYID>.p8` and paste the single-line output. The `.p8` is downloadable only once at key-creation time — if you've lost it, revoke the key and create a new one.
2. **Seed the Match repo.** Run the **Rotate certificates** workflow from the Actions tab (Run workflow → `workflow_dispatch`). Because the private Match repo starts empty, the `certificates` lane generates a fresh App Store distribution cert + provisioning profile and pushes them encrypted. The lane authenticates with the App Store Connect API key (no Apple ID prompt) and uses an ephemeral keychain on the runner; the resulting profile is named `match AppStore <bundle-id>`.
3. **Confirm end-to-end.** Trigger the **Deploy to TestFlight** workflow manually to build the currently pinned `.upstream-version` and upload it to TestFlight.

Once step 3 succeeds, the pipeline is fully autonomous: upstream releases deploy on their own, builds refresh on schedule, and signing material self-rotates.

## Secret and certificate rotation

Nothing in this stack emails you on expiry — set calendar reminders when you create each one, and note each expiry date wherever you keep the secret values.

| Secret / artifact | Lifetime | Failure signature when expired |
| --- | --- | --- |
| `RELEASE_BOT_TOKEN` | as set on the fine-grained PAT (1 year recommended) | **Check upstream release** workflow fails at `gh release list` with a 401 |
| `MATCH_GIT_BASIC_AUTHORIZATION` | as set on the Match PAT (1 year recommended) | Deploy fails inside `match` with a 401 cloning the certs repo |
| `APPLE_KEY_*` (App Store Connect API key) | no automatic expiry; only revoked manually | Deploy fails with `Authentication credentials are missing or invalid` |
| App Store distribution certificate | 1 year (Apple) | Build fails during code signing — `match` reports no valid certificate |
| Provisioning profile (`match AppStore <bundle-id>`) | 1 year (Apple) | Same as the certificate |

To rotate certificate / profile, run the **Rotate certificates** workflow from the Actions tab (`workflow_dispatch`) — it runs the `certificates` lane on a CI runner using the same secrets as the deploy workflow, and Match detects the expired material in the certs repo and regenerates everything in-place. The workflow also runs monthly on a `cron: "0 10 5 * *"` schedule; because Match only regenerates missing or expired material, the scheduled run is a no-op while the cert is still valid, so it effectively self-heals within a month of expiry.

To rotate a PAT, regenerate it on GitHub and replace the value under **Settings → Secrets and variables → Actions**. To rotate the API key, revoke and recreate it in App Store Connect, then update the `APPLE_KEY_*` secrets as in step 1 of first-run setup. Neither can be fully automated: GitHub fine-grained PATs and App Store Connect API keys have no creation API, so minting the new credential is always a manual step.

## TestFlight build expiry

Apple expires TestFlight builds 90 days after upload. The **Deploy to TestFlight** workflow runs on a `cron: "0 10 1 */2 *"` schedule (every two months, on the 1st at 10:00 UTC) to rebuild the currently pinned `.upstream-version` and refresh the expiry — even when no upstream release has landed.

## Bumping upstream manually

```sh
echo v0.13.1-beta > .upstream-version
git add .upstream-version
git commit -m "bump upstream audiobookshelf-app to v0.13.1-beta"
git push
```

The deploy workflow will run on push to `main`.
