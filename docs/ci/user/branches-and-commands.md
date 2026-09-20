# Branches and Commands

Once a repository has a pipeline enabled, the branch you are standing on decides what a Genesis command is allowed to do. This page says which branch each command expects, why it refuses where it refuses, and how to ask a command about the version an environment is actually running rather than about the tip of its branch.

Most of this applies only to a repository with a pipeline. With `pipeline.enabled` off, no command is refused for the branch you are standing on and none of them switches branches under you. The one thing you still meet is the pair of deployed-commit flags at the end of this page, which are refused outright off a pipeline, because the branch session that makes them safe opens only under one.

## The branches a pipeline repository carries

A pipeline repository keeps the environment files on one branch and the delivered state on others. The branch you are on falls into one of five kinds, and Genesis works out which by reading the environments the repository declares rather than by matching a naming pattern.

| Kind | What it is | Who writes to it |
|------|------------|------------------|
| Control | The branch the environment files live on, and the source every delivery is read from | You, and the commands that commit on your behalf |
| Deployment | One branch per deployment, named for the deployment slug, holding what was delivered to it | `genesis propagate` |
| Pull request | The branch a propagation run opens a pull request from, for an environment whose `require_pr` asks for one | `genesis propagate`, which rewrites it each run |
| Artifacts | The branch reserved for a deployment's artifacts | Nothing yet. Genesis recognises the name so that it can refuse a command standing there, and no command writes the branch |
| Feature | Any other branch, which is where you do work that is headed for control | You |

The last four are derived, which means Genesis composes their names from the environments it finds rather than reading them from configuration. A branch that matches none of them is a feature branch.

## The two classes of command

Every pipeline-aware command declares one of two classes, and `genesis help` prints the class beside the command so you can see it without running anything.

A **pre-deploy** command changes what will be delivered, so it belongs on control or on a feature branch cut from control. The help listing marks it `[control]`. The commands in this class are `genesis new`, `genesis <env> check-secrets`, `genesis <env> secrets`, `genesis <env> add-secrets`, `genesis <env> rotate-secrets`, `genesis <env> remove-secrets`, `genesis pipeline-apply`, `genesis pipeline-status`, `genesis pipeline-describe`, `genesis pipeline-hold`, and `genesis pipeline-release`.

`genesis propagate` declares the same class and is excused the check, because it goes to control of its own accord inside its own session and leaves you on the branch you started on. It takes no argument and you can run it from anywhere.

A **deployed-state** command reports on or acts on what was deployed, so it runs against a deployment branch and Genesis puts you back where you started when it finishes. The help listing marks it `[env branch]`. The commands in this class are `genesis <env> deploy`, `genesis <env> bosh`, and `genesis <env> info`.

The class is declared once, at the command's registration, and the same declaration drives both the refusal and the help marker, so the listing and the refusal cannot disagree about what a command expects.

## What a pre-deploy command refuses

Run a pre-deploy command from a deployment branch, a pull request branch, or an artifacts branch and it refuses at `DATAERR` without switching anything. Running `genesis <env> add-secrets` from a deployment branch is the refusal you are most likely to meet first. Derived branches never carry a commit made by hand, so the way out is to move to control or to a feature branch cut from it, and the refusal prints the checkout that does it.

The refusal switches nothing on purpose. You chose the branch you are on, so putting you somewhere else without asking would be Genesis deciding where your work belongs.

Control itself is permitted, with one exception. Where `pipeline.source_control.control_requires_pr` is set, the branch protection it derives blocks a direct push, so a command that commits on control expects a feature branch instead and says so.

## The three conditions a feature branch has to meet

A feature branch is permitted only where all three of these hold, and the refusal names the one that failed along with the command that fixes it.

1. **Control has been fetched.** Genesis measures your branch against control's tip as it stands on the remote, so a clone that has never fetched control has nothing to measure against. Fetch it, and cut the branch from what arrives.

2. **The branch descends from control's refreshed tip.** A branch cut before the last change landed on control carries an older set of environment files, so a check for an existing environment would be reading a topology that has moved on. Rebase onto the refreshed tip.

3. **The branch is not named for an environment.** A branch called `prod2` occupies the ref that a deployment branch for an environment named `prod2` would need, so the two could never stand side by side. Rename the branch.

Genesis refreshes control before it classifies your branch, whether it ends up permitting the branch or refusing it, so where a command ends tells you nothing about whether it fetched. Two commands make no fetch of their own, which are `genesis pipeline-status` under `--no-refresh` and `genesis pipeline-describe`, and both answer from what the repository already holds.

A detached HEAD is neither control nor derived, and it is allowed through. A repository with no commits at all is refused earlier, by the pre-flight, which names the commit that fixes it.

## Asking about the deployed commit

A deployment branch's tip is the newest thing delivered to an environment, which is not always the version the environment is running. The commit an environment is actually running is recorded in its last successful deployment, and two flags ask Genesis to target that commit instead of the tip.

`--redeploy` on `genesis <env> deploy` and `--as-deployed` on `genesis <env> bosh`, `genesis <env> info`, `genesis <env> check-secrets`, `genesis <env> add-secrets`, `genesis <env> rotate-secrets`, and `genesis <env> remove-secrets` mean the same thing. Both target the deployed commit, which is checked out detached inside the branch session, and the branch you started on is restored when the command finishes.

`genesis <env> bosh` and `genesis <env> info` target the deployed commit by default, because a report on an environment means a report on what it is running. The others target the tip unless you say otherwise.

Naming either flag in a repository whose pipeline is off is refused at `CONFIG`. The deployed commit is recorded in every repository, but the branch session that makes checking it out safe opens only under a pipeline, so outside one there is nothing to assert the tree clean, to hold the switch lock, or to put you back where you started.

Naming either flag for an environment whose file is not in the tree you are standing on is refused at `CONFIG` as well. That file travels on control and on the environment's own deployment branch, so standing on one environment's deployment branch and asking about another is the state that raises it.
