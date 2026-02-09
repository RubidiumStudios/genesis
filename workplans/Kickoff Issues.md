# Pipeline Concerns and Design Notes

## 1. Failed Deployments at Environment N

**Problem:** How to recover when environment N fails (where N is not the first environment).

### Current Behavior (Cache-Based)

- Deploying environment N requires N-1 to have passed, using the git revision from N-1's successful deployment
- When N fails, the repo is not in a state that allows successful redeployment (contrary to original design premise)
- Manual CLI deployment doesn't work because we'd have to manually merge:
  - Previously successful deployment cached values
  - Previously successful deployment of N
- Genesis CLI does not support this manual merge operation

### New Behavior (Branch-Based)

- Branch for N may still have a configuration that causes failure
- **Recovery options:**
  - Revert the change that caused failure and redeploy (if no migrations or non-revertible changes)
  - Make a commit to the branch that fixes the problem and redeploy

---

## 2. Environment Transitions

### Gating Mechanism

**Old way:** Hard gate requiring N-1 success before deploying N
- Implemented directly through Concourse
- Or disconnected on monitored changes using a base repo that "passes" as each environment succeeds

### Inherited vs Non-Inherited Files

| Type | Description | Example |
|------|-------------|---------|
| **Cached (inherited)** | Shared files common to all environments up to N-1 | `c.yml`, `c-aws.yml`, `c-aws-useast2.yml` |
| **Changes (non-inherited)** | Ancestral files not shared with other environments | `c-aws-useast2-hs.yml`, `c-aws-useast2-hs-prod.yml` |

**Example:** For `c-aws-useast2-hs-prod.yml`:
- N-1 might be `c-aws-useast2-staging.yml`
- Since staging doesn't have `hs` in the name, the `hs` file is a "change" for prod

### Branch-Based Propagation

**Requirements:**
- Propagate changes to N+1 branches when N succeeds
- Applies to: cached files, general manifest structures, ops, bin, etc.

**Key Question:** What about files that don't propagate forward?
- Example: `c-aws-useast2-hs-prod.yml` is prod-specific
- Should it push to staging branch? **Probably not** - staging doesn't need prod-specific config
- Need to identify which files are ancestral (shared) vs environment-specific

### Proposed Solution: Live Branch

1. **`live` branch** receives all changes
2. On change detection, push (or create PRs) to appropriate environment branches:
   - Change to `c.yml` → push to head of pipeline (propagates through all environments)
   - Change to `c-aws-useast2-hs-prod.yml` → push only to prod branch
3. **Considerations:**
   - Logic needed to determine ancestral vs environment-specific files
   - Analysis needed for files that exist on some branches but not others
   - Branch hygiene: avoid unmaintainable branches with extra/missing files
   - Distribution from live to other branches should be atomic (pipeline handles this)

---

## 3. Organizational Controls

### Deployment Authorization

**When (auto vs manual):**
- Pipeline control file indicates if progression is automatic or manual per environment
- This is the minimum required control

**Who:**
- Concourse controls which users can deploy to which pipelines/environments
- Branch-based system adds git-level controls:
  - Limit who can push to certain branches (e.g., only certain users push to prod)
  - PR mechanisms allow commit messages to document:
    - What changes are being made
    - Why
    - Special considerations (migrations, downtime, etc.)

---

## 3a. Missed/Aggregated Deployments

### The Problem

When N-1 deploys multiple times before N is triggered (manual trigger):
- Required migrations or changes might be missed
- N could deploy without necessary changes from N-1

**Example scenario:**
1. BOSH release X introduces new MTA handling (old way still supported)
2. Release X+Y removes old way
3. N-1 deploys multiple times
4. N finally deploys after old way is removed
5. **Result:** N deploys without necessary changes for new MTA handling

### Open Questions

1. Should N be required to deploy after each N-1 deployment?
2. Can we track which N-1 changes must be included in N?
3. If using PRs for propagation:
   - How to allow merges to N only up to a required point?
   - How to ensure merges happen in correct order?
   - How to prevent missing required changes?

---

## Additional Workflow Notes

- **Sandbox** will likely have every upstream change (releases, stemcells)
- These changes **will not** trigger higher environments
- **Staging trigger** is expected to proceed through nonProd and Prod
- **Failure handling:**
  - Options: fail-back or fail-forward
  - In branch-based system, revert may not always be possible
- **Unskippable changes:**
  - Some updates (like migrations) cannot be skipped
  - Investigating GitHub metadata (tags, commit messages) to mark changes as unskippable
