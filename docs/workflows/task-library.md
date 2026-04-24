# Task Library

A task library lets you version-control custom pipeline task files in a separate git repository and reference them by name from any Genesis pipeline job. This keeps operator-written task logic out of the environment repository.

## Configuration

Task library config lives under `configuration.task_library` in `ci/configuration.yml` (multi-file format) or in the `configuration:` section of `pipeline.yml`:

```yaml
configuration:
  task_library:
    uri:           https://github.com/org/pipeline-tasks.git
    branch:        main             # optional, default 'main'
    path:          tasks            # optional subdirectory within the repo
    resource_name: tasks            # optional Concourse resource name, default 'tasks'
    auth:
      type:        ssh-key          # 'ssh-key' or 'token'
      private_key: ((library-key))  # for ssh-key
```

All keys except `uri` are optional.

## How it works

### Concourse

When `task_library` is configured, Genesis:

1. Declares a `git` resource (named by `resource_name`, default `tasks`) pointing at the external repository.
2. Adds a `get: tasks` (non-triggering) step to every deploy and redeploy job's `in_parallel` block.
3. Adds `{ name: tasks }` to the inputs list of every task config, making the library available at `/tmp/build/<id>/tasks/` inside the running task.
4. Sets the `GENESIS_TASK_LIBRARY_PATH` environment variable in each task to the path where task YAML files can be found:
   - Without `path`: `tasks` (equals the resource_name)
   - With `path: tasks`: `tasks/tasks`

### GitHub Actions

`Provider::GithubActions` adds an equivalent `actions/checkout@v4` step that checks out the task library repository into the `path` subdirectory of the runner workspace. Token-based auth is forwarded as a `${{ secrets.* }}` expression.

## Authentication for private repositories

### SSH key

```yaml
task_library:
  uri:  git@github.com:org/private-tasks.git
  auth:
    type:        ssh-key
    private_key: ((task-library-key))
```

### Personal access token / GitHub App token

```yaml
task_library:
  uri:  https://github.com/org/private-tasks.git
  auth:
    type:     token
    password: ((library-token))
```

`username` defaults to `x-oauth-basic` when omitted (works with GitHub PATs and Apps). Supply an explicit `username` if your git host requires one.

## Path resolution

The `GENESIS_TASK_LIBRARY_PATH` variable tells a genesis task where to look for library task files at runtime:

| Configuration | `GENESIS_TASK_LIBRARY_PATH` |
|---------------|----------------------------|
| `resource_name: tasks` (no path) | `tasks` |
| `resource_name: tasks`, `path: tasks` | `tasks/tasks` |
| `resource_name: lib`, `path: ci/tasks` | `lib/ci/tasks` |

Within a running task the full file path would be `$GENESIS_TASK_LIBRARY_PATH/<task-name>.yml`.

## Example: shared ops tasks

```yaml
# ci/configuration.yml
configuration:
  task_library:
    uri:    https://github.com/my-org/genesis-pipeline-tasks.git
    branch: stable
    path:   tasks
    auth:
      type:     token
      password: ((github-tasks-token))
```

Resulting Concourse pipeline fragment:

```yaml
resources:
  - name: tasks
    type: git
    icon: source-repository
    source:
      uri:      https://github.com/my-org/genesis-pipeline-tasks.git
      branch:   stable
      username: x-oauth-basic
      password: ((github-tasks-token))

jobs:
  - name: sandbox-deployment
    plan:
      - do:
        - in_parallel:
            - get: sandbox-changes
            - get: git
            - get: tasks
              trigger: false
        - task: bosh-deploy
          config:
            inputs:
              - name: sandbox-changes
              - name: git
              - name: tasks
            params:
              GENESIS_TASK_LIBRARY_PATH: tasks/tasks
              ...
```

## GitHub Actions equivalent

For the same configuration, `Provider::GithubActions` adds:

```yaml
steps:
  - name: Checkout repository
    uses: actions/checkout@v4
    with:
      fetch-depth: 0

  - name: Checkout task library (tasks)
    uses: actions/checkout@v4
    with:
      repository: my-org/genesis-pipeline-tasks
      ref:        stable
      path:       tasks/tasks
      token:      ${{ secrets.GITHUB_TASKS_TOKEN }}
```

## Decision matrix

| Scenario | Recommended config |
|----------|--------------------|
| Shared ops tasks across multiple pipelines | `task_library` with a dedicated repo |
| Single pipeline, few tasks | Inline task config (no library needed) |
| Private tasks repo | `auth: { type: token, password: ... }` |
| Monorepo with tasks in a subdirectory | `uri: <same-repo>`, `path: <subdir>` |
