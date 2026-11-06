# Translating a v2 Layout

A v2 pipeline described its topology in `ci.yml` as a layout: a few lines of directives and chains, such as `auto sandbox` and `sandbox -> staging -> production`. A v3 repository has no layout. Each environment says where it sits in its own file, under `genesis.pipeline`, and a repository that still carries a pipeline `ci.yml` is refused by every pipeline command. This page translates a layout into those keys. The operator's guide *Pipeline Migration: v2 to v3* covers the rest of the move.

## Chains become `prior_env`

Each `A -> B` in a chain becomes one key in B's file:

```yaml
# staging.yml
genesis:
  pipeline:
    prior_env: sandbox
```

`sandbox -> staging -> production` is two keys: `prior_env: sandbox` in `staging.yml`, and `prior_env: staging` in `production.yml`. An environment at the head of a chain sets none. Independent chains, such as one per region, need nothing more: each environment names only the one before it.

The key is read merged, so it can be set once in a site file that several environments share. That is rarely what a chain wants, since each step names a different predecessor.

An environment has one predecessor. A layout that fed one environment from two others, `sandbox-a -> staging` and `sandbox-b -> staging`, has no direct translation. Pick the one that should gate it, or make the two a chain.

## `auto` becomes the absence of `manual`

The defaults are reversed:

- **In v2**, an environment was manual unless an `auto` pattern matched it.
- **In v3**, an environment deploys automatically unless its file sets `manual: true`.

So:

- **Matched by `auto`:** set nothing.
- **Not matched by `auto`:** set `genesis.pipeline.manual: true`.

```yaml
# production.yml
genesis:
  pipeline:
    prior_env: staging
    manual: true
```

A glob such as `auto *-sandbox` has no counterpart; mark each environment it did not match. A site file shared by every production environment is a good place for `manual: true`.

Miss this step and a tier that was manual starts deploying on its own.

## Several layouts

`ci.yml`'s `layouts` could name several topologies in one file and pick one with `genesis repipe <layout>`. A v3 deployment root has one pipeline. Topologies that must stay apart live in separate deployment roots, each with its own `.genesis/config` and pipeline.

## What the layout used to imply

Some of a layout's behaviour moved with it, and some changed:

- **What triggers a deploy.** A root environment no longer watches path-filtered files on the default branch, and a downstream one no longer reads a cache. `genesis propagate` delivers each control commit to an environment's own branch once the environments before it have deployed it, and the branch moving is what triggers the deploy.
- **Which files count.** An environment's files are still its hierarchy: for `client-aws-us1-prod`, `client.yml`, `client-aws.yml`, `client-aws-us1.yml` and `client-aws-us1-prod.yml`, together with `ops/`, the kit, and `genesis.pipeline.track_additional_files`. A commit touching only files no earlier environment reads is delivered straight away.
- **Manual environments' notices.** A manual environment's notify job posts what deploying would change, where Slack is configured, and its deploy waits for a person.
- **Aliases.** v2's `boshes.<env>.alias` shortened job names. v3 names every job after the environment, `deploy-<env>`, and has no alias.
