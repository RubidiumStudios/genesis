# CLI Commands

Genesis provides a family of `pipeline-*` commands for working with CI pipelines, along with three deprecated commands that predate them and four retired ones. This document covers all of them.

## genesis pipeline-apply

The `pipeline-apply` command gives the pipeline its shape. It compiles a CI pipeline definition and, where the provider has one to set, deploys it to the CI platform.

```
genesis pipeline-apply [<pipeline-layout>] [options]
```

`genesis repipe` is the deprecated spelling of this command. It warns, then does exactly what `pipeline-apply` does, and it keeps the `push` alias. Use `pipeline-apply` in anything new.

`pipeline-apply` compiles the pipeline your repository configures and uploads it to the CI system that pipeline names, through `fly set-pipeline` where that system is Concourse. It prompts for confirmation before uploading unless you pass `--yes`. The configuration is the `pipeline:` section of `.genesis/config`, and the provider is read from `pipeline.provider.type` rather than from any flag.

There is no fallback to `ci.yml`. A repository whose `pipeline:` section is absent or not enabled has no pipeline to apply, and `repipe` says so instead of compiling anything. A repository that still carries a `ci.yml` with a top-level `pipeline:` key is refused earlier still, by a check that names the migration, so no pipeline command reads that file.

The optional positional argument selects which pipeline layout to deploy when your configuration defines multiple layouts via `pipeline.layouts`. If you have a single `pipeline.layout`, the argument is ignored. If you have multiple layouts and one is named `default`, it is selected when no argument is given.

### Options

`--yes` or `-y` skips the `fly set-pipeline` confirmation prompt. This is useful for automation.

`--dry-run` or `-n` generates the pipeline YAML and prints it to stdout without deploying to Concourse. Combine this with output redirection to save the generated YAML for review.

`--target` or `-t` specifies the Concourse target name (as shown by `fly targets`). By default, the target name is derived from the layout name.

`--config` or `-c` is kept for compatibility and nothing reads it any more. The pipeline comes from the `pipeline:` section of `.genesis/config`.

`--paused` or `-P` keeps the pipeline paused after uploading. By default, Genesis unpauses the pipeline after a successful `set-pipeline`.

`--output-dir` or `-o` writes compiled pipeline artifacts to a directory instead of deploying. This produces the pipeline YAML, an `ast.json` file containing the full AST, and any other provider output files.

`--skip-vault` bypasses Vault connectivity during compilation. When set, the pipeline is compiled without connecting to Vault, which means spruce vault operators will not be resolved. This is useful for local inspection of the generated YAML.

`--debug-dir` writes intermediate compiler artifacts to a directory for debugging. The artifacts are numbered by compilation stage:

```
01-parsed.json        # Parser output
02-ast-source.json    # AST source representation (Genesis concepts)
03-pipeline.json      # Resolved generic pipeline (resource_types, resources, jobs, groups)
04-pipeline.dot       # Graphviz DOT source
05-description.txt    # Human-readable description
06-output-pipeline.yml # Final provider output
```

### Examples

Compile and deploy the pipeline:

```bash
genesis pipeline-apply
```

Preview what is generated without deploying:

```bash
genesis pipeline-apply --dry-run > pipeline.yml
```

Write all compiler artifacts to a directory for inspection:

```bash
genesis pipeline-apply --output-dir ./debug --skip-vault
```

Dump every intermediate stage of compilation:

```bash
genesis pipeline-apply --debug-dir ./stages --skip-vault
```

The provider is whichever type `pipeline.provider.type` names. Concourse is the only one Genesis can compile for today. The `github-actions` type validates and resolves on the CLI side, but it has no compiling class yet, so a repository set to it is told so rather than being given a pipeline. The `manual` type has no pipeline to set at all, and the command says which stage it skipped and exits successfully.

## genesis graph (deprecated)

The `graph` command generates a Graphviz DOT representation of your pipeline topology. Pipe the output through a Graphviz renderer to produce an image. It warns that it is deprecated, and it is the one command left that calls the legacy generator directly.

```
genesis graph [<pipeline-layout>] [options]
```

`graph` reads `ci.yml` and draws the legacy topology. For the Mermaid flowchart the compiler writes, use `genesis pipeline-graph` instead.

```bash
# Generate a PNG image
genesis graph | dot -Tpng > pipeline.png

# Generate SVG
genesis graph | dot -Tsvg > pipeline.svg
```

Options: `--config`, which is kept for compatibility.

## genesis describe (deprecated)

The `describe` command prints a human-readable description of your pipeline, listing each environment, whether it deploys automatically or requires manual approval, and what triggers it. It warns, then delegates to `genesis pipeline-describe`, which is the command to use instead.

```
genesis describe [<pipeline-layout>] [options]
```

Example output:

```
Pipeline: my-cf-deployments
Workflow: my-cf-deployments
  sandbox              sandbox-deployment  [auto]
  staging              staging-deployment  [manual] (triggered by sandbox)
  production           production-deployment  [manual] (triggered by staging)
```

Options: `--config`, which is kept for compatibility.

## Retired Pipeline Commands

The four commands below ran inside a legacy Concourse task. They are retired and none of them runs any more. Each is still registered in `bin/genesis` so that dispatch refuses it by name, which makes a legacy pipeline fail loudly rather than deploy something inconsistent. They are described here so that a reader who meets one in an old pipeline knows what it did.

### genesis ci-pipeline-deploy

Ran inside a Concourse task to deploy an environment. It authenticated to Vault using AppRole credentials from environment variables, loads the Genesis environment, and called `genesis deploy`. After deployment it committed state files and deployment artifacts back to the Git repository.

It required these environment variables: `CURRENT_ENV`, `GIT_BRANCH`, `OUT_DIR`, `WORKING_DIR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, `VAULT_ADDR`. Either `GIT_PRIVATE_KEY` or both `GIT_USERNAME` and `GIT_PASSWORD` must be set.

### genesis ci-show-changes

Ran inside a Concourse task to show what would change if an environment were deployed. It computed the diff between the current deployment and the proposed manifest by querying the BOSH director, and notification jobs used it to show operators what changes were pending before they approved a deployment.

### genesis ci-generate-cache

Ran inside a Concourse task after a successful deployment to generate a cache of shared configuration files for downstream environments. The cache was committed to the Git repository so that downstream environments could detect when upstream changes had been tested.

### genesis ci-pipeline-run-errand

Ran inside a Concourse task to execute a BOSH errand after deployment. The errand name came from the `ERRAND_NAME` environment variable.

## Code Path Summary

```mermaid
flowchart TD
    A[genesis pipeline-apply] --> H[Genesis::CI::Compiler::Parser]
    H --> I[Genesis::CI::Compiler::Validator]
    I --> J[Genesis::CI::Compiler::ASTBuilder]
    J --> K[Genesis::CI::Compiler::PipelineDescriptor]
    K --> L{pipeline.provider.type}
    L -->|concourse| M[Genesis::CI::Provider::Concourse]
    L -->|manual| P[Nothing to set]
    M --> Q[ProviderCompiler::Concourse]
    Q --> G[fly set-pipeline]
```
