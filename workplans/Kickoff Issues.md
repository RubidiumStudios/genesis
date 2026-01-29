Notes on Current/Future Pipeline Concerns

1) How to deal with a failed deployment at enironment N where N is not the first environment:

- When deploying environment N, currently we require that it passed N-1 and use the revision of the git repo that was used to deploy N-1 successfully.  However, in the case where N fails, and we need to deploy the non-inherited aspects of N, the repo is not in a state that will result in a successful deployment. (Contrary to original design premise of the pipelines).

- Old cached-base system would not correctly be deployed using manual deployment on the cli, because we'd manually have to merge the previously successful deployment cached values with the previously successful deployment of N, and genesis cli does not support a way of doing that.

- New branch based system will still have this problem of branch for N having a configuration that causes failure, but we can revert the change that caused the failure and redeploy if walking back that change is valid (ie no migrations or other non-revertible changes were made).  Or we can make a commit to the branch that fixes the problem for N and redeploy.

2) How to deal with transitions between environments

- Old way uses a gating system when N requires N-1 to be successful before deploying N.  This is a hard gate, and prevents deployment of N until N-1 is successful.  It can be done directly through concourse, or be disconnected on the monitored changes, but using a base repo for showing sequential progression that just 'passes' as each environment is successfully deployed.

- There are inherited and non-inherited aspects of each environment (referred to in the pipeline as cached and changes).  Generally speaking, the changes are only for ancestral files that are not shared with other environments, and the cached files are the shared files that are common to all environments up to N-1.  For example, for c-aws-useast2-hs-prod.yml, the cached files would be c.yml, c-aws.yml, c-aws-useast2.yml, but  c-aws-useast2-hs.yml and c-aws-useast2-hs-prod.yml would be changes that would be detected for in the pipeline job for deploying that environment.  In this case, N-1 might have been c-aws-useast2-staging.yml (note that staging doesn't have hs in the name, so the hs file is a change for prod).

- For the new branch-based system, we need to propagate the changes to N+1 branches when N is successfully deployed.  This would only apply for what was done with the cached files now, as well as the general manifest structures for the whole genesis kit.  We also need to figure out what other changes get pushed (ie ops, bin, etc).  However, it begs the question about what to do about ancestral and deployment files that don't propagate forward.  For example, if we have a c-aws-useast2-hs-prod.yml file that is only for prod, and we deploy prod successfully, do we push that file to the staging branch?  Probably not, as staging doesn't need to know about prod-specific configuration.  So we need to be able to identify which files are ancestral (shared) and which are specific to the environment being deployed.

- Possible solution: have a 'live' branch that takes changes, then when it detects changes to specific files, it pushes (or makes pull requests) to the environment branches that need those changes.  For example, if we change c.yml, it would push to the head of the pipeline that will propagate through all the environments, but if we change c-aws-useast2-hs-prod.yml, it would only push to the prod branch.  This would require some logic to determine which files are ancestral and which are specific to the environment.  It also would need some analysis to determine if those files are existant of the other branches (probably not), and if not, what does that mean for branch hygiene - we don't want to result in a bunch of highly unmaintainable branches with files that are extra and/or missing.  We'd also need that distribution from live to the other branches to be an atomic operation in a pipeline so the pipeline generation tool with create that.

3) Need to deal with organizational controls around when/who can deploy to certain environments

- Currently we use a pipeline control file that indicates if progression is triggered automatically or manually for each environment.  This is the minimal control we need to support.

- The who is answered by the concourse system itself, as only certain users have access to deploy to certain pipelines/environments.

- By moving to branch-based deployments, we can also use git controls to limit who can push to certain branches (ie only certain users can push to prod branch).  This would add an additional layer of control beyond the pipeline control file.  It also allows for propagation through Pull Request mechanisms, and would allow commit messages to be used to indicate what changes are being made, why, and if any special considerations need to be made (ie migrations, downtime, etc).

3a) How to deal with missed/aggregated deployments

- Currently, you can have N-1 deployed multiple times before N is deployed if it is not automatically triggered.  This means that if there was a deployment that was required to progress to the next version of the application, it might be missed if N is not deployed after each N-1 deployment.  This could lead to a situation where N is deployed without a required migration, or other necessary change that was made in N-1.  IE: the bosh release used one way of handling mtas prior to release X, then for release X, it made a new way available but still supported the old way.  At some point X+y, the old way is removed.  If N-1 was deployed multiple times, and N was not deployed until after the old way was removed, then N would be deployed without the necessary changes to handle the new way of mtas.

- How can we ensure that required changes are not missed when deploying N.  Do we require that N be deployed after each N-1 deployment?  Or do we have a way of tracking what changes were made in N-1 that need to be included in N, and ensure that those changes are included when N is deployed, regardless of how many times N-1 was deployed?  If using PRs to propagate changes, how do we ensure that a) we only allow merges to N up to the required point, b) that merges are done in the correct order, and c) that we don't miss any required changes?

Additional notes on workflow:
- Sandbox can and most likely will have every change from upstream (releases and stemcells for example)
- These changes will not trigger higher environments
- When Staging is triggered it is expected for proceed through nonProd and Prod
- If there are failures two possible options fail-back and fail-forwardIn the branch plan, revert may not be possible
- Some updates (like migrations) may not allow change to be skipped, investigating tags and commit messages (Github Metadata) as a way to tag as unskippable.