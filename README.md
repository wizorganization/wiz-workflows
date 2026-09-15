# Wiz reusable workflows

Centralized GitHub Actions reusable workflows for Wiz CLI directory/code and
container-image scans.

## Workflows

| Workflow | Target | Selectable scan types |
| --- | --- | --- |
| `wiz-dir-scan.yml` | A checked-out repository or directory | `vulnerabilities`, `sast`, `iac`, `secrets`, `sensitive-data`, `malware`, `software-supply-chain`, `ai-models`, or `all` |
| `wiz-image-scan.yml` | An existing registry image or supplied image archive | `vulnerabilities`, `secrets`, `sensitive-data`, `software-supply-chain`, `malware`, or `all` |

Both workflows:

- authenticate with `WIZ_CLIENT_ID` and `WIZ_CLIENT_SECRET`;
- save human-readable, JSON, SARIF, and console-log reports;
- upload reports to the calling GitHub Actions run, even when the scan fails;
- publish results to Wiz by default (set `publish: false` to keep results out of
  **Findings > Code & Build Scans**);
- preserve Wiz CLI exit codes, including policy failure exit code `4`;
- expose the artifact name, artifact URL, and Wiz CLI exit code as reusable
  workflow outputs.

The repository also provides platform-agnostic composite actions for scanning a
locally available image and tagging a successfully scanned registry digest.
They contain no image build, registry login, pull, or push logic, so callers can
place them between their platform-specific build and publish steps.

Wiz CLI scans use branch-aware managed policy profiles. Pushes to `main` or
`production`, and pull requests targeting either branch, use production
policies. All other branches use staging policies. For individual or
comma-separated scan type selections, the workflows use Wiz CLI's
`--disabled-scanners` option to disable every unselected analyzer and apply
only the managed policies mapped to the selected scanners.

The default `policy_profile: auto` performs this branch detection. Set
`policy_profile: staging` or `policy_profile: production` to force a profile,
or pass `policies` to completely override managed policy selection. Precedence
is `policies`, then `policy_profile`, then automatic branch detection.

Directory policy profiles:

| Scan type | Staging policy | Production policy |
| --- | --- | --- |
| `vulnerabilities` | `Arun-Vuln-Staging` | `Arun-Vuln-Prod` |
| `sast` | `Arun-Sast-Staging` | `Arun-Sast-Prod` |
| `iac` | `Arun-IaC-Staging` | `Arun-IaC-Prod` |
| `secrets` | `Arun-Secrets-Staging` | `Arun-Secrets-Prod` |
| `sensitive-data` | `Arun-Sensitive-Data-Staging` | `Arun-Sensitive-Data-Prod` |
| `software-supply-chain` | `Arun-Software-Mgmt-Staging` | `Arun-Software-Mgmt-Prod` |
| `malware` | `Arun-Malware-Staging` | `Arun-Malware-Prod` |

Image scans use the same mappings for `vulnerabilities`, `secrets`,
`sensitive-data`, `software-supply-chain`, and `malware`. Directory scans that
select only `ai-models` must provide `policies`, because that scanner has no
managed policy mapping in this repository.

## Prerequisites

1. Create a Wiz CLI CI/CD service account with the minimum project scope needed
   by the callers.
2. Store its credentials as Actions secrets named `WIZ_CLIENT_ID` and
   `WIZ_CLIENT_SECRET` in each caller repository, or as organization secrets
   restricted to approved repositories.
3. If this repository is private, allow approved caller repositories under
   **Settings > Actions > General > Access**.
4. Create a release tag for this repository. For production callers, replace
   `v1` in the examples with a reviewed full commit SHA for immutable reuse.

## Directory/code scan

```yaml
name: Wiz directory scan

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  wiz-directory:
    uses: arun-wiz/wiz-workflows/.github/workflows/wiz-dir-scan.yml@main
    with:
      scan_types: all
      path: .
      publish: true
      artifact_retention_days: 14
    secrets:
      WIZ_CLIENT_ID: ${{ secrets.WIZ_CLIENT_ID }}
      WIZ_CLIENT_SECRET: ${{ secrets.WIZ_CLIENT_SECRET }}
```

Select individual or multiple scan types with a comma-separated value:

```yaml
    with:
      scan_types: sast,secrets
```

To apply tenant-specific policies, pass their exact, case-sensitive names:

```yaml
    with:
      scan_types: sast,secrets
      policies: My SAST blocking policy,My secrets blocking policy
```

To force a managed profile instead of using automatic branch detection:

```yaml
    with:
      scan_types: all
      policy_profile: production
```

## Container-image scan workflow

The reusable workflow pulls and scans an existing image. It can optionally tag
a successful scan in the Wiz Trusted Image Database. It does not build or push
images and contains no cloud-platform-specific authentication.

```yaml
name: Wiz image scan

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  wiz-image:
    uses: arun-wiz/wiz-workflows/.github/workflows/wiz-image-scan.yml@main
    with:
      image: ghcr.io/example/application:1.2.3
      pull_image: true
      scan_types: all
      artifact_retention_days: 14
    secrets:
      WIZ_CLIENT_ID: ${{ secrets.WIZ_CLIENT_ID }}
      WIZ_CLIENT_SECRET: ${{ secrets.WIZ_CLIENT_SECRET }}
```

To scan an image archive already present in the caller repository, disable
pulling:

```yaml
    with:
      image: application.tar
      pull_image: false
      scan_types: vulnerabilities,secrets
```

For a private registry, also pass `registry`, `registry_username`, and the
optional `REGISTRY_PASSWORD` secret. Do not use `secrets: inherit`; pass only
the credentials required by the workflow.

## Composite image actions

Use the composite actions when the image must be scanned before it is pushed.
Because composite actions run as steps, the caller's build, scan, push, and tag
operations share one runner and the same local Docker image:

```yaml
steps:
  - name: Build image
    run: docker build --tag "$IMAGE" .

  - name: Scan local image
    uses: arun-wiz/wiz-workflows/.github/actions/wiz-image-scan@main
    with:
      image: ${{ env.IMAGE }}
      scan_types: all
      wiz_client_id: ${{ secrets.WIZ_CLIENT_ID }}
      wiz_client_secret: ${{ secrets.WIZ_CLIENT_SECRET }}

  # Authenticate and push with platform-specific caller steps, setting DIGEST.

  - name: Add pushed digest to Wiz Image Trust
    uses: arun-wiz/wiz-workflows/.github/actions/wiz-image-tag@main
    with:
      image: ${{ env.IMAGE }}
      image_digest: ${{ steps.push.outputs.digest }}
      wiz_client_id: ${{ secrets.WIZ_CLIENT_ID }}
      wiz_client_secret: ${{ secrets.WIZ_CLIENT_SECRET }}
```

The scan action applies Wiz policies and fails before the caller's push step.
The tag action accepts the registry-assigned digest after the push. Callers are
responsible for uploading the action's report directory, which defaults to
`/tmp/wiz-image-reports`.

### Add a trusted image to Wiz

Set `tag_image: true` to run `wizcli tag` after a successful published scan and
add the image digest to the Wiz Trusted Image Database:

```yaml
    with:
      image: ghcr.io/example/application:1.2.3
      pull_image: true
      scan_types: all
      tag_image: true
```

The image must exist locally and have a registry-assigned digest. A pulled
registry image normally satisfies both requirements. For an exported image
archive or when Wiz CLI cannot resolve the digest locally, pass it explicitly:

```yaml
      image: application.tar
      pull_image: false
      tag_image: true
      image_digest: sha256:0123456789abcdef...
```

`tag_image` requires `publish: true`. The workflow runs `wizcli tag` only when
the scan exits successfully; policy failures and operational scan errors are
never added to the trusted image database. The tag command's console output is
included in the uploaded report artifact as `wizcli-tag.log`.

## Running both target types

Call both reusable workflows as separate jobs. They can run in parallel and
produce independently named artifacts in the same caller run:

```yaml
jobs:
  directory:
    uses: arun-wiz/wiz-workflows/.github/workflows/wiz-dir-scan.yml@main
    with:
      scan_types: all
    secrets:
      WIZ_CLIENT_ID: ${{ secrets.WIZ_CLIENT_ID }}
      WIZ_CLIENT_SECRET: ${{ secrets.WIZ_CLIENT_SECRET }}

  image:
    uses: arun-wiz/wiz-workflows/.github/workflows/wiz-image-scan.yml@main
    with:
      image: ghcr.io/example/application:1.2.3
      scan_types: all
    secrets:
      WIZ_CLIENT_ID: ${{ secrets.WIZ_CLIENT_ID }}
      WIZ_CLIENT_SECRET: ${{ secrets.WIZ_CLIENT_SECRET }}
```

## Important behavior

- `fail_on_policy: true` (default) makes Wiz policy failures fail the job.
  Setting it to `false` suppresses only exit code `4`; authentication, command,
  network, and other operational errors still fail the job.
- `policy_hits: DISABLED` (default) includes all detected findings in reports.
  Use `BLOCK` or `AUDIT` to narrow report visibility. This setting does not
  change the scan's exit code.
- `publish: false` adds Wiz CLI's `--no-publish`; report artifacts are still
  uploaded to GitHub.
- `policy_profile: auto` uses the pull request base branch when available and
  otherwise uses the current ref name. `main` and `production` select the
  production profile; every other branch selects staging.
- The effective branch, policy profile, and exact policy list are recorded in
  the artifact metadata and GitHub job summary.
- The Wiz CLI binary comes from Wiz's documented HTTPS `latest` endpoint and
  its version is captured in every artifact. GitHub actions are pinned to full
  commit SHAs and tracked by Dependabot.

## Documentation used

- [Integrate Wiz CLI with GitHub](https://docs.wiz.io/docs/github-pipeline)
- [Scan directories with Wiz CLI](https://docs.wiz.io/docs/scan-directories-with-wiz-cli)
- [Scan and tag container images with Wiz CLI](https://docs.wiz.io/docs/scan-and-tag-container-images-with-wiz-cli)
- [How Wiz CLI works](https://docs.wiz.io/docs/how-wiz-cli-works)
- [GitHub reusable workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [GitHub Actions security hardening](https://docs.github.com/en/code-security/tutorials/secure-your-organization/protect-against-threats)
