# Layout DSL

The layout DSL is a small language for defining how Genesis environments flow through your deployment pipeline. Instead of writing Concourse YAML by hand, you describe the relationships between environments in a few lines of text, and Genesis generates all the jobs, resources, triggers, and notification hooks automatically.

The DSL belongs to the legacy configuration, and the compiler still reads it wherever a repository hands it one, parsing a layout into a workflow with the same graph of nodes and edges a workflow written out longhand produces. A v3 repository does not write one. Its topology comes from `genesis.pipeline.prior_env` in the environment files, one edge per environment, and the rest of this page is the reference for the language the compiler accepts rather than a description of how a v3 repository is configured.

## Basic Syntax

A layout is a multi-line string containing two kinds of statements: directives and chains. Statements are separated by newlines or semicolons. Lines beginning with `#` are comments and are ignored.

```yaml
layout: |
  # Auto-deploy sandbox environments
  auto sandbox-*

  # Define the deployment chain
  sandbox -> staging -> production
```

## Environment Chains

An environment chain describes which environments trigger which other environments. The `->` operator means "on successful deployment, trigger the next environment." You can chain as many environments as you like:

```yaml
layout: |
  sandbox -> preprod -> prod
```

This creates three deployment jobs. When sandbox finishes deploying, it triggers the preprod job. When preprod finishes, it triggers prod.

You can define multiple independent chains:

```yaml
layout: |
  us-sandbox -> us-staging -> us-prod
  eu-sandbox -> eu-staging -> eu-prod
```

These two chains operate independently. A change that flows through the US chain does not affect the EU chain and vice versa.

You can also define convergent chains where multiple environments feed into one:

```yaml
layout: |
  sandbox-a -> staging
  sandbox-b -> staging
  staging -> production
```

Here both sandbox-a and sandbox-b trigger staging independently. Either one completing successfully will start a staging deployment.

Every environment referenced in a chain must have a corresponding entry in `pipeline.boshes`. The parser validates this and reports an error if it finds an environment name that does not match any BOSH director definition.

## The auto Directive

By default, every environment in the pipeline requires manual approval before deploying. The `auto` directive marks environments for automatic deployment, meaning they deploy as soon as their trigger conditions are met without waiting for someone to click a button in the Concourse UI.

```yaml
layout: |
  auto sandbox
  sandbox -> staging -> production
```

In this example, sandbox deploys automatically when changes are detected on the monitored Git branch. Staging and production both require manual approval.

The `auto` directive supports glob patterns so you can auto-deploy groups of environments at once:

```yaml
layout: |
  auto *-sandbox
  auto *-preprod

  us-sandbox -> us-preprod -> us-prod
  eu-sandbox -> eu-preprod -> eu-prod
```

The `*` wildcard matches any sequence of characters. The pattern `*-sandbox` matches `us-sandbox`, `eu-sandbox`, or any other environment whose name ends with `-sandbox`. Multiple `auto` directives are allowed and their patterns are cumulative.

## How Triggers Work

The first environment in each chain (one that nothing else triggers) is called a "root" environment. Root environments trigger when Git detects changes to environment files on the monitored branch. Specifically, Genesis watches for changes to files that affect that environment: its own YAML files, the `ops/` directory, and `kit-overrides.yml`.

Non-root environments, the ones that appear after a `->`, trigger differently. They watch their own deployment branch, which is where a file reaches them. Nothing is cached between environments and no cache resource exists. `genesis propagate` delivers a control commit to a downstream environment's branch once every environment upstream of it has deployed the files that commit touches, so the branch moving is the signal, and until it moves there is nothing for the downstream job to fetch.

For non-auto environments, the trigger still fires, but instead of starting a deployment immediately, it runs a "show changes" notification job that posts a Slack or email notification saying that changes are staged and ready for review. The actual deployment job then waits for manual approval.

## File Watching

Genesis uses hierarchical YAML file naming conventions to determine which files affect which environments. Given an environment named `client-aws-us1-prod`, Genesis watches these files:

```
client.yml
client-aws.yml
client-aws-us1.yml
client-aws-us1-prod.yml
```

Each level of the hierarchy represents progressively more specific configuration, and the files an environment reads are what the propagation run compares a control commit against. A commit that touches only a file no upstream environment reads is delivered straight away, and a commit that touches a shared parent file waits until every environment above has deployed it.

That wait is what keeps untested configuration out of production. The downstream environment deploys the same commit the upstream one deployed, off its own branch, rather than a copy of the upstream environment's files taken after the fact.

## Complete Example

Here is a realistic layout for a multi-region deployment with proto-BOSH:

```yaml
pipeline:
  name: cf-deployments

  boshes:
    proto:
      alias: proto-bosh
    us-sandbox:
      alias: sandbox
      url: https://bosh.sandbox.example.com
      # ... credentials ...
    us-staging:
      alias: staging
      url: https://bosh.staging.example.com
      # ... credentials ...
    us-prod:
      alias: prod
      url: https://bosh.prod.example.com
      # ... credentials ...

  layout: |
    # Proto-BOSH deploys itself, feeds into sandbox
    auto proto
    proto -> us-sandbox

    # Standard progression through staging to production
    auto us-sandbox
    us-sandbox -> us-staging -> us-prod
```

The proto-BOSH environment is a create-env deployment (no BOSH director URL). It deploys automatically, and on success, triggers the sandbox. Sandbox also deploys automatically. Staging and production both require manual approval.

The `alias` fields make Concourse job names readable: instead of `us-sandbox-cf-deployment`, you get `sandbox-cf-deployment`.

## Multiple Layouts

When you have multiple independent pipeline topologies, use `layouts` instead of `layout`:

```yaml
layouts:
  us: |
    auto us-sandbox
    us-sandbox -> us-staging -> us-prod
  eu: |
    auto eu-sandbox
    eu-sandbox -> eu-staging -> eu-prod
```

Deploy a specific layout:

```bash
genesis pipeline-apply us
genesis pipeline-apply eu
```

When using `layouts`, you must specify which layout to deploy. If you have a layout named `default`, it is selected automatically when you run `genesis pipeline-apply` without arguments.
