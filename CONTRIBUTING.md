# Contributing

When contributing to this repository, please first discuss the
change you wish to make via issue, email, or any other method with
the owners of this repository before making a change.

Please note we have a Code of Conduct, please follow it in all
your interactions with the project.

## Pull Request Process

1. Ensure that the software still builds, launches properly, and
   that the test suite still passes.

2. Provide the context of the discussion with the repository
   owners and core team members that lead to the submission of the
   pull request.  This may be as simple as a link to an issue.

3. After review and approval, your Pull Request will be merged by
   a repository owner.

## The push gate

Run `make hooks` once per clone.  It points `core.hooksPath` at the
tracked `.githooks/` directory, after which pushing requires that
`make test` has passed for the code being pushed.

`make test` records its success automatically; the hook checks that the
record still matches the working tree.  The comparison is on file
contents, so a rebase or a branch switch does not invalidate a run that
is still valid.  It takes well under a tenth of a second.

A change confined to documentation is allowed through without a run:
`.md` files anywhere outside `t/`.

Everything else blocks, including several things that look like
documentation but are not:

- `LICENSE`, `NOTICE`, `COPYING`, `AUTHORS` and friends, **whatever
  their extension**.  These are stronger than blocked: a passing suite
  does **not** clear them.  Running `make test` says the code works, not
  that relicensing was intended, so the hook compares the push against
  what the remote already has rather than against the test record —
  which re-testing would otherwise regenerate.  Such a push requires
  `--no-verify`, deliberately.
- `.md` files **under `t/`** — kit fixtures there carry a `README.md`
  and a `ci/release_notes.md` that the compilation tests read.
- `.pod` files — `t/sanity-tests/pod-complete.t` validates their
  structure, so a POD edit can genuinely fail the suite.
- comment-only edits to `.pm` files — a comment may be commented-out
  code, and POD blocks and heredocs change how the file parses.
- `Makefile`, `t/bin/*`, `t/test-manifest.txt` — they decide what runs.
- `.gitignore` — it changes `git ls-files`, which is what the record is
  built from.

The hook prints the files it saw change in both directions, so a refusal
names what caused it and an allowance shows what it waved through.

Pushes that only delete refs are not gated.  To bypass the gate for a
single push, use `git push --no-verify`.

The gate is local.  Git has no hook that runs for a pull request and
GitHub runs none server-side, so a pull request is still gated only by
CI.

## Test your changes

In order to test your changes, you can use the following development workflow:

- Clone this repo
- Do some changes
- Build a development `genesis` CLI running `make release VERSION=x.y.z`
- Symlink the generated `genesis-x.y.z` (or `genesis-x.y.z-dirty` if you
  didn't commit your code yet) file to `genesis` with
  `ln -s genesis-x.y.z-dirty genesis` (to be done once only)
- Add the current directory in your `PATH` with `export PATH=$PWD:$PATH` (to
  be done only once per shell session) or just copy it to you `~/bin`
  directory if it exists and is on your path
- Go to some deployment directory, check the genesis CLI you'll be using with
  `which genesis` and `genesis version`
- Run the usual `genesis` CLI commands and verify it behaves as expected
