# Apple Code Signing Action

Reusable GitHub Action for signing Apple applications via Block's internal codesigning service (`codesign_helper` Lambda + Buildkite).

## Setup

Reach out to **#mdx-ios** on Slack to get codesigning configured for your repo. They will provision the required infrastructure and set up two repository secrets:

| Secret | Description |
|---|---|
| `OSX_CODESIGN_ROLE` | IAM role ARN for OIDC authentication with AWS |
| `CODESIGN_S3_BUCKET` | S3 bucket for artifact transfer |

## Usage

The calling job must have `id-token: write` permission for OIDC authentication with AWS.

```yaml
# Example workflow — replace the build and release steps with your own
name: Build and Release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: macos-latest
    permissions:
      contents: write
      id-token: write # Required — the action uses OIDC to authenticate with AWS
    steps:
      # ...
      # Your build step — produces an unsigned .app or .zip
      # ...

      # apple-codesign-action — signs and notarizes the artifact
      - name: Codesign and Notarize
        id: codesign
        uses: block/apple-codesign-action@XXX # use the latest version ref
        with:
          osx-codesign-role: ${{ secrets.OSX_CODESIGN_ROLE }}
          codesign-s3-bucket: ${{ secrets.CODESIGN_S3_BUCKET }}
          unsigned-artifact-path: <path-to-unsigned-artifact> # .app or .zip containing a .app
          entitlements-plist-path: <path-to-entitlements>     # Optional

      # Use the signed artifact in subsequent steps
      # steps.codesign.outputs.signed-artifact-path
      # ...
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `osx-codesign-role` | **yes** | — | `${{ secrets.OSX_CODESIGN_ROLE }}` |
| `codesign-s3-bucket` | **yes** | — | `${{ secrets.CODESIGN_S3_BUCKET }}` |
| `unsigned-artifact-path` | **yes** | — | Local path to unsigned artifact (`.app` or `.zip` containing a `.app`) |
| `entitlements-plist-path` | no | `''` | Path to entitlements plist to bundle into the signing payload |
| `artifact-name` | no | `$GITHUB_SHA-$GITHUB_RUN_ID` | Unique S3 key suffix |
| `branch` | no | `main` | Branch override for the signing pipeline (only honored for approved repos) |

## Outputs

| Output | Description |
|---|---|
| `signed-artifact-path` | Local path to the downloaded signed artifact |
| `build-number` | Build number from the signing service |
| `signing-duration` | Wall-clock seconds the signing took |

## Project Resources

| Resource                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| [CODEOWNERS](./CODEOWNERS)                 | Outlines the project lead(s)                                                   |
| [GOVERNANCE.md](./GOVERNANCE.md)           | Project governance                                                             |
| [LICENSE](./LICENSE)                        | Apache License, Version 2.0                                                    |
