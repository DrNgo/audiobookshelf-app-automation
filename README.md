# audiobookshelf-app TestFlight pipeline

Builds the iOS app from [advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app) and uploads it to a private TestFlight, automatically, every time upstream cuts a new release.

## How it works

1. **`check-upstream-release.yml`** runs every 24 hours and on-demand. It compares the upstream's latest release tag against `.upstream-version`. If they differ, it opens a PR bumping `.upstream-version` and enables auto-merge on it.
2. The merge lands a push on `main` touching `.upstream-version`.
3. **`deploy-testflight.yml`** triggers on that push: it clones upstream at the pinned tag, runs `npm ci && npm run generate && npx cap sync ios && pod install`, then runs the `ios beta` fastlane lane to sign with Match, build with `gym`, and upload to TestFlight via `pilot`.

You can also dispatch `deploy-testflight.yml` manually from the Actions tab to redeploy the currently pinned version.

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
| `RELEASE_BOT_TOKEN`             | Fine-grained personal access token with **Contents: read/write** and **Pull requests: read/write** on this repo. Required so bump PRs trigger the deploy workflow (the default `GITHUB_TOKEN` cannot trigger other workflows). |
| `DEVELOPER_APP_IDENTIFIER`      | Your reverse-DNS bundle identifier (e.g. `com.example.audiobookshelf`).                                                                                                                                                        |
| `DEVELOPER_PORTAL_TEAM_ID`      | 10-character team ID from [developer.apple.com → Account → Membership](https://developer.apple.com/account).                                                                                                                   |
| `APPLE_KEY_ID`                  | App Store Connect API key ID. Create at [App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys](https://appstoreconnect.apple.com/access/api). Use **Admin** or **App Manager** role.        |
| `APPLE_ISSUER_ID`               | Issuer ID from the same page.                                                                                                                                                                                                  |
| `APPLE_KEY_CONTENT`             | Base64-encoded contents of the `.p8` private key file. Generate with `base64 -i ~/Downloads/AuthKey_<KEYID>.p8` and paste the resulting single-line string verbatim.                                                           |
| `MATCH_GIT_URL`                 | HTTPS clone URL of your private Match repository (e.g. `https://github.com/you/match-certificates`).                                                                                                                           |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `username:token` string for that repo, where `token` is a fine-grained PAT with **Contents: read/write** on the Match repo. The Fastfile base64-encodes this before passing to Match.                                          |
| `MATCH_PASSWORD`                | Passphrase used to encrypt the Match repository contents. Pick any long random string the first time you run Match; remember it.                                                                                               |
| `TEMP_KEYCHAIN_PASSWORD`        | Any long random string. Used as the password for the ephemeral keychain created on the CI runner.                                                                                                                              |

## Local secrets via direnv + Bitwarden

`flake.nix` provides Ruby 3.4 + bundler + CocoaPods + Node 22, and `.envrc` resolves every secret from a single Bitwarden item named `audiobookshelf-app testflight` via `helpers/bitwarden.sh`. `use flake` evaluates the dev shell automatically when nix-direnv is enabled.

1. Install [Nix](https://nixos.org/) (with flakes), [direnv](https://direnv.net/) + `nix-direnv`, the [Bitwarden CLI](https://bitwarden.com/help/cli/), and `jq`.
2. Create one Bitwarden Login item named `audiobookshelf-app testflight`. Add a **custom field** for each variable in the secrets table above. Two gotchas:
   - Strip any leading or trailing whitespace from every value — Bitwarden preserves it and an extra space in `DEVELOPER_APP_IDENTIFIER` will make match fail with `Could not find App ID`.
   - `APPLE_KEY_CONTENT` must be the base64 of the **same** `.p8` whose ID is in `APPLE_KEY_ID`. Generate with `base64 -i ~/Downloads/AuthKey_<KEYID>.p8` and paste the single-line output. The `.p8` file is downloadable only once at key-creation time — if you've lost it, revoke the key and create a new one.
3. From this repo: `direnv allow` (only needed once; subsequent `cd` entries auto-load).
4. Verify with `echo "$DEVELOPER_APP_IDENTIFIER"` — should print your bundle id with no trailing newline noise.

## First-run setup

Once direnv has loaded the secrets, populate the private Match repo with a fresh App Store distribution cert and provisioning profile:

```sh
cd fastlane
bundle install
bundle exec fastlane certificates
```

The `certificates` lane uses the App Store Connect API key (no Apple ID prompt), creates an ephemeral keychain (no macOS login prompt), imports the cert into it, and pushes the encrypted cert + profile to your private match repo. The profile is named `match AppStore <bundle-id>`.

After that succeeds, copy every secret listed above into GitHub Actions secrets and trigger the **Deploy to TestFlight** workflow manually to confirm CI works end-to-end.

## Secret and certificate rotation

Nothing in this stack emails you on expiry — set calendar reminders when you create each one. Recommended practice: add a `<SECRET_NAME>_EXPIRES_ON` custom field (date) alongside the secret in the same Bitwarden item.

| Secret / artifact | Lifetime | Failure signature when expired |
| --- | --- | --- |
| `RELEASE_BOT_TOKEN` | as set on the fine-grained PAT (1 year recommended) | **Check upstream release** workflow fails at `gh release list` with a 401 |
| `MATCH_GIT_BASIC_AUTHORIZATION` | as set on the Match PAT (1 year recommended) | Deploy fails inside `match` with a 401 cloning the certs repo |
| `APPLE_KEY_*` (App Store Connect API key) | no automatic expiry; only revoked manually | Deploy fails with `Authentication credentials are missing or invalid` |
| App Store distribution certificate | 1 year (Apple) | Build fails during code signing — `match` reports no valid certificate |
| Provisioning profile (`match AppStore <bundle-id>`) | 1 year (Apple) | Same as the certificate |

To rotate certificate / profile, re-run `bundle exec fastlane certificates` locally — Match detects the expired material in the certs repo and regenerates everything in-place. To rotate a PAT, regenerate it on GitHub and replace the value in **Settings → Secrets → Actions** (and the Bitwarden custom field). To rotate the API key, revoke and recreate in App Store Connect, then re-do step 1.3 from the initial setup.

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

## Local deploy

Runs the same pipeline CI runs — clone upstream, build, upload to TestFlight:

```sh
export UPSTREAM_TAG="$(cat .upstream-version)"
scripts/prepare-upstream.sh
cd fastlane
bundle exec fastlane ios beta
```

The signed `.ipa` is uploaded to TestFlight and also left at `build/App.ipa`.
