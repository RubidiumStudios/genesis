# Workflows
1) Manual -- no ci.yml
  Genesis operates on the current branch...

2) Pipelined - ci.yml exists.
There is a live branch (configurable, defaults to 'live'), and then there is a branch for each target (not each .yml file, but only those that are viable targets)

Anything pushed to the live branch will trigger a distribution pipeline that will figure out which files changed, and which branches they should go to (by looking at the layouts in the ci.yml file)


# Repo Components

How to handle the parts of the deployment repo:

## The base environment files (ancestral structure split on hyphens)

Each viable deployment target, and thus branch, is based on an environment file.  These files in turn "inherit" any file name that is comprised of 1 to N-1 of its naming components.  For example, the file "c-aws-euwest-1-prod" would inherit from "c-aws-euwest-1", "c-aws-euwest", "c-aws", and "c".  This allows for a hierarchical structure of environment files, where more specific files can override values from more general ones.  These are not required to be saturated, meaning that a file can exist without all of its parent files being present.  The deployment pipeline will need to be able to handle this and only apply the files that are present for a given target.

Progression from one deployment to another is determined by the layouts defined in the ci.yml file.  For example, a layout might specify that changes to certain files should trigger deployments to specific targets.  The pipeline will need to be able to read these layouts and determine which branches to deploy to based on the files that changed in the live branch.  What gets passed to subsequent deployments is based on shared ancestry.  Ie if c-aws-euwest-1-lab gets deployed, and c-aws-euwest-1-prod is a downstream deployment, then c.yml, c-aws.yml, c-aws-euwest.yml, and c-aws-euwest-1.yml would be passed to the prod deployment, but not c-aws-euwest-1-lab.yml.  This allows for a structured and efficient way to manage environment configurations across multiple deployment targets.  Likewise, if c-aws.yml changes for example, it would enter the pipeline at the first environment that makes use of it, in this case c-aws-euwest-1-lab, and then be passed to all downstream deployments that share ancestry with it, in this case c-aws-euwest-1-prod as well.

### Common Case: Kit Version

The most common case for the deployment pipeline to be triggered is setting a new version of the kit in the base environment file.  For example, if we set the kit version to "3.1.0" in the c.yml file, then the first environment in the layouts that references c.yml would be triggered, and then all downstream deployments that share ancestry with it would also be triggered.  This allows for a simple and efficient way to manage kit versions across multiple deployment targets, and ensures that all relevant deployments are updated when a new kit version is set.

This does however reveal an Achilles heel in the process.  If a downstream environment file explicitly states a different kit version, the deployment would be trigger but not pick up on the inherited version change.  This should at least cause a warning.  Need to consider how to handle this situation, as it could lead to confusion if a deployment is triggered but does not actually pick up the changes due to an explicit override in a downstream environment file.  We also don't want to stop on the detection of a non-deployment change, because other changes (see ops and inherits below) could still be relevant to subsequent deployments.  This is a tricky situation, and we will need to carefully consider how to handle it in the deployment pipeline to ensure that it is both efficient and effective in managing deployments across multiple targets.

## The ops files (contents of the ops/ directory)

These files are basically manifest fragments that are provided by the environment that mimic kit features.  They are not necessarily tied to a specific environment, but they can be.  For example, there might be an ops file that defines a database configuration that is used by multiple environments, and then there might be another ops file that defines a specific database configuration for a specific environment.

The deployment pipeline will need to be able to handle these files and apply them to the appropriate deployments based on the layouts defined in the ci.yml file.  The ops files can also be used to define common configurations that are shared across multiple environments, which can help to reduce duplication and improve maintainability.  Since these files are specified as part of the kit.features array in the environment files, if we want to ensure their changes trigger the correct deployments, we will need to analyze which enviornment and ancestry files reference them, and then look at the layouts to determine which deployments those environments feed into.  For example, if an ops file is referenced by an environment that feeds into a specific deployment, then changes to that ops file should trigger a deployment to that target.  This will require the pipeline to be able to analyze the relationships between the environment files and the ops files, and then determine which deployments to trigger based on those relationships.

The alternative is that we trigger the manifest rendering as a precondition, and if nothing changes, then we don't trigger a deployment, but pass the changed files through to the next pipeline stage.  This would be more efficient, but it would also require the pipeline to be able to render the manifest and determine if there are any changes before deciding whether to trigger a deployment or not.  This could potentially add some complexity to the pipeline, but it could also help to reduce unnecessary deployments and improve overall efficiency.  Having the deployment manifest stored in exodus (v3.1.0+) will make this more feasible.

## Explicit inheritance (the "genesis.inherits" key in the environment files)

This is a more direct way to specify inheritance between environment files.  For example, if an environment file specifies that it inherits from another environment file, then it will automatically receive all of the configurations from that parent file.  This can be used to create more complex relationships between environment files, and can help to further reduce duplication and improve maintainability.  The deployment pipeline will need to be able to handle this explicit inheritance and apply the configurations accordingly when deploying to the appropriate targets based on the layouts defined in the ci.yml file.

Similar to ops files, we could detect changes in deployment manifests, and if the file doesn't change, then we skip the deployment and pass the changed files down the line.

## BOSH configs (currently under ops/)

Genesis v3.1.0 introduced the concept of BOSH configs per deployment (effectively reversing BOSH manifest v2.0 decoupling).  Overrides were allowed in the form of ops or inherits files (the latter being preferred).  We need to determine if they should be stored somewhere specific to the purpose, and how to determine where they would be injected into the pipeline.  Manifest rendering as a detection mechanism wouldn't work, because they don't affect the manifest -- they affect the configuration file that is uploaded to the BOSH director, as generated by the various kit hooks (cloud-config and cpi).

## Scripts (contents of the scripts/ directory)

These files are basically executable scripts that can be used to perform various tasks during the deployment process.  They can be tied to specific environments or they can be more general.  These are most likely employed by the reaction hooks on deploys.  This is where it gets complicated, because they don't materially affect the manifest, so we can't really use them as a basis for determining whether to trigger a deployment or not.  However, they can still be an important part of the deployment process, and we will need to ensure that they are executed correctly during the deployment process.  The deployment pipeline will need to be able to handle these scripts and execute them at the appropriate times during the deployment process based on the layouts defined in the ci.yml file.  This may require some additional logic in the pipeline to determine when to execute these scripts and how to handle any outputs or side effects that they may produce.

## bin/genesis

The pipeline is designed to use the embedded version of Genesis for all operations, so it is important that bin/genesis propagates through the pipeline correctly.  However, we may need to have break-glass situations for using a different version.

## Future-proofing other files.

There may be other files in the deployment repo that we want to future-proof for use in the deployment pipeline.  For example, there might be configuration files, documentation files, or other types of files that are not currently being used in the deployment process, but that we want to be able to use in the future.  The deployment pipeline will need to be flexible enough to accommodate these types of files and allow them to be integrated into the deployment process as needed based on the layouts defined in the ci.yml file.  This will help to ensure that the deployment pipeline is adaptable and can evolve over time as new requirements and use cases arise.

In the past, we've just stuffed everything under ops, such as the inherits files and the bosh-configs files, but we need to generically support any new types of files that we want to use in the deployment process, and not just assume that they will all be ops files.  This will help to ensure that the deployment pipeline is flexible and can accommodate a wide range of different file types and use cases as needed.  It will also help to improve the overall maintainability and scalability of the deployment process by allowing us to easily integrate new types of files without having to make significant changes to the underlying structure of the deployment repo.

# Homogeneity of Deployment Process

Unlike the current pipeline/layout/caching system, we want the act of deployment to be as homogeneous as possible regardless of how it is enacted.  While the curent pipeline has specific pipeline-based genesis commands that operate different than the `deploy` command that users call from the command line, we want to unify these as much as possible.

## Detection of Pipeline vs Manual Mode

As noted above, the presence of a ci.yml file will be the primary mechanism for determining whether we are in manual mode or pipeline mode.  If the ci.yml file is present, then we are in pipeline mode and we will need to follow the layouts defined in that file to determine how to handle deployments.  If the ci.yml file is not present, then we are in manual mode and we can simply deploy to the current branch without needing to worry about layouts or triggering other deployments based on file changes.  This will allow us to have a clear and consistent way to determine how to handle deployments based on the presence or absence of the ci.yml file, and will help to ensure that the deployment process is as homogeneous as possible regardless of how it is enacted.

We will need to ensure that we can 'break-glass' if necessary in pipeline mode to allow for explicit manual deployments, but we'll also need to ensure the ability to recover from such situations and reintegrate back into the pipeline as smoothly as possible.  This will require some additional logic in the deployment pipeline to allow for manual deployments when necessary, while still maintaining the overall structure and flow of the pipeline for automated deployments based on the layouts defined in the ci.yml file.

## Manual Mode

This is the current `genesis deploy` command as-is.  No consideration of file changes or layouts.  Just deploy the current local branch contents to the target environment.  This is the simplest mode of operation and will allow users to quickly and easily deploy to their target environments without needing to worry about the complexities of the deployment pipeline or the layouts defined in the ci.yml file.  This mode will be useful for quick deployments, testing, and other situations where users want to have direct control over the deployment process without needing to worry about triggering other deployments based on file changes.

## Pipeline Mode

### Deploy on Commit to Live Branch

The "Yellow Brick Road" route for pipeline mode would be to make changes to the "live" branch, which would trigger a special component of the pipeline that is responsible for analyzing the changes in the live branch and determining which deployments to trigger based on the layouts defined in the ci.yml file.  This component would need to be able to read the ci.yml file, analyze the file changes in the live branch, and then determine which deployments to trigger based on those changes and the relationships defined in the layouts.  This would allow for a structured and efficient way to manage deployments across multiple targets based on changes made to the live branch, while still maintaining a clear and consistent deployment process that is guided by the layouts defined in the ci.yml file.

This would ensure a clean approach to managing deployments sequentially (and in parallel when indicated by the layouts) based on changes made to the live branch, without triggering cascading waves of intermediary deployments that would occur if we were to trigger deployments directly from the branches associated with each deployment target.  By centralizing the deployment triggering logic in a single component that analyzes changes in the live branch and determines which deployments to trigger based on the layouts defined in the ci.yml file, we can ensure a more efficient and manageable deployment process that is guided by clear rules and relationships defined in the layouts, while still allowing for flexibility and adaptability as needed.

### Explicit Deployments to Specific Targets (TBD)

This is the troublesome case, but it needs to be supported.  If we run genesis deploy, we would absolutely need to ensure that there is a safety net that can be bypassed if necessary, but enough that it will prevent most accidents.

1. If on "live" branch, then we can deploy to any target, but we need to ensure that we are aware of the consequences of our actions.  This would most likely be done to rescue a failed deployment, but could result in a fractured state (live may contain newer changes that haven't propagated to the target branch yet), so we need to ensure that we are aware of the potential consequences and have a plan for how to handle any issues that may arise from this type of deployment, especially an accidental revert on the next deployment through the pipeline.

1. Check if the current branch is the same as the environment being deployed:
  1. TBD if true
  2. TBD if false

1. Reconciliation stages
1. What about subsequent targets that would normally be triggered from the current target?
