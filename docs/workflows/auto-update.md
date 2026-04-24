# Auto-Update: update-genesis-assets

The `update-genesis-assets` job automatically tracks new Genesis kit releases and
Genesis binary releases, bumps the version file in your repository, and commits
the result.  This removes the manual step of editing `kit.yml` every time the
upstream kit or binary publishes a new version.

---

## When to enable

Enable `update-genesis-assets` when:

- Your kit version is pinned in a file that the pipeline checks out (e.g.
  `kit.yml`, `.genesis/kits/cf.yml`)
- You want each environment to pick up new versions automatically rather than
  waiting for a manual commit
- You operate a standard GitOps flow where pipeline-created commits on a branch
  trigger downstream jobs

Do **not** enable it when:

- The kit version is managed by another system (e.g. Dependabot, a vendor
  lock-in policy)
- Your pipeline branch is frozen between releases and drift would cause
  unexpected re-deploys

---

## Configuration

```yaml
configuration:
  auto_update:
    enabled:       true
    kit:           cf              # kit name (cf → cf-genesis-kit on GitHub)
    org:           genesis-community
    file:          kit.yml        # repo-relative path to the version file
    label:         concourse      # CI_LABEL in commit messages (default: concourse)
    period:        24h            # release check frequency (default: 24h)
    update_kit:    true           # bump kit version (default: true)
    update_genesis: true          # bump genesis binary (default: true)
    target_branch: auto-update    # push to this branch instead of the control branch
    auth_token:    ((github-token))  # GitHub token for release checks (shared)
    kit_auth_token: ((kit-token))   # per-kit override of auth_token
    genesis_auth_token: ((genesis-token))  # per-genesis override of auth_token
    api_url:       https://github.example.com/api/v3  # GitHub Enterprise only
```

### Required fields

| Field | Description |
|-------|-------------|
| `enabled: true` | Opt-in — the job is not emitted without this |
| `kit` | Kit name without the `-genesis-kit` suffix |
| `org` | GitHub organization that owns the kit repository |
| `file` | Path (relative to repo root) of the file Genesis reads for the kit version |

All other fields have defaults or are omitted when not needed.

---

## How it works

### Resources emitted

When `update_kit: true` (default):

```yaml
- name: kit-release
  type: github-release
  icon: package-variant
  check_every: 24h
  source:
    user:         genesis-community
    repository:   cf-genesis-kit
    access_token: ((github-token))
```

When `update_genesis: true` (default):

```yaml
- name: genesis-release
  type: github-release
  icon: leaf
  check_every: 24h
  source:
    user:         genesis-community
    repository:   genesis
    access_token: ((github-token))
```

When `target_branch` differs from the control branch:

```yaml
- name: git-autoupdate
  type: git
  icon: source-branch
  source:
    uri:    https://github.com/org/repo.git
    branch: auto-update
```

### Job structure

```yaml
- name: update-genesis-assets
  plan:
    - in_parallel:
        - get: git
        - get: kit-release
          trigger: true
        - get: genesis-release
          trigger: true
    - task: list-kits
      ...
    - task: update-genesis
      ...
    - task: fetch-kit
      ...
    - put: git          # or git-autoupdate when target_branch is set
      params:
        repository: git
        rebase: true
```

Both `kit-release` and `genesis-release` trigger the job independently — a
kit release does not need to coincide with a genesis release to trigger an
update run.

### Task scripts

**`list-kits`** — calls `genesis list-kits` and writes available versions.

**`update-genesis`** — runs `genesis fetch` to update the genesis binary in
the worktree and commits:

```
[concourse] bump genesis to 2.8.14
```

**`fetch-kit`** — runs `genesis fetch-kit` to download the new kit version,
updates `kit.yml`, and commits:

```
[concourse] bump kit cf to 2.3.1
```

The label in square brackets is controlled by `configuration.auto_update.label`
(or the legacy `commit_label` key).

---

## Selective updates

### Kit only (no genesis binary)

```yaml
configuration:
  auto_update:
    enabled:        true
    kit:            cf
    org:            genesis-community
    file:           kit.yml
    update_genesis: false
```

`genesis-release` is not checked out, the `update-genesis` task is not run,
and no `genesis-release` resource is emitted.

### Genesis binary only (no kit bump)

```yaml
configuration:
  auto_update:
    enabled:    true
    kit:        cf
    org:        genesis-community
    file:       kit.yml
    update_kit: false
```

`kit-release` is not checked out and `list-kits`/`fetch-kit` are not run.

---

## Pushing to a separate branch

By default the auto-commit is pushed back to the control branch (the same
branch the pipeline monitors).  To send it to a feature or auto-update branch:

```yaml
configuration:
  auto_update:
    enabled:       true
    kit:           cf
    org:           genesis-community
    file:          kit.yml
    target_branch: auto-update
```

A `git-autoupdate` resource is emitted that tracks `auto-update`.  The final
`put:` step in the job uses `git-autoupdate` instead of `git`, so the
auto-commits never land directly on the control branch.  A PR or manual merge
from `auto-update` → control branch then triggers the normal pipeline.

---

## Auth

### Shared token

```yaml
auth_token: ((github-token))
```

Used for both `kit-release` and `genesis-release`.

### Per-resource overrides

```yaml
auth_token:         ((shared-token))
kit_auth_token:     ((kit-specific-token))
genesis_auth_token: ((genesis-specific-token))
```

`kit_auth_token` overrides `auth_token` for the kit resource only;
`genesis_auth_token` overrides it for the genesis resource only.

### GitHub Enterprise

```yaml
api_url: https://github.example.com/api/v3
```

Applied only to the `kit-release` resource (the genesis binary is always
fetched from github.com).

---

## Legacy key mapping

The following keys from earlier pipeline formats are accepted and normalized:

| Legacy key | Current key |
|------------|-------------|
| `kit_version_file` | `file` |
| `commit_label` | `label` |

When `file` is present and `enabled` is not declared, `enabled` defaults to
`true` for backwards compatibility.

---

## Auditing auto-commits

Every commit the pipeline pushes follows the pattern:

```
[<label>] bump <component> to <version>
```

To list all auto-update commits on a branch:

```sh
git log --oneline --grep='\[concourse\]' origin/main
```

Substituting `concourse` with whatever `label` you configured.  To see only
kit bumps:

```sh
git log --oneline --grep='\[concourse\] bump kit'
```

To see who triggered a given bump (which Concourse build):

```sh
git show <commit> --format="%B" | head -5
```

The commit message body includes the genesis command output, which records the
kit version that was active before the bump.

---

## Concourse group

The job is placed in a dedicated `genesis-updates` group so it does not
clutter the main deployment view.  All release-tracking resources appear only
in that group.
