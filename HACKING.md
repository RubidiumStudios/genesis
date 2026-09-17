Hacking on Genesis
==================

A Style Guide
-------------

Genesis is written in Perl, and we adhere to the following style
guidelines:

  - **use_underscore_names** - No camelCaseHere!
  - **no function prototypes** - Use destructuring binds to get
    named arguments out of `@_` in your subs:

    ```
    sub do_thing {
        my ($a, $b, $c) = @_;
    }
    ```

  - **only use core modules** - This eases portability concerns.
    Sometimes, you can't avoid it (as with `JSON::PP`) -- in that
    case, look at the `./pack` script and make sure we can embed
    the non-core module in a distributed script file.

Where a Sentence About the Code Belongs
---------------------------------------

Every sentence you want to write about the code has exactly one home,
and which one is decided by what the sentence does.

  - **It explains what a method does, takes, returns, or raises,
    in any detail** -- it belongs in the method's `=head2` in the
    sibling `.pod` file.  `t/sanity-tests/pod-complete.t` requires
    that entry, so writing the same thing as a comment above the
    method is writing it twice, and the two will drift.

  - **It justifies why the code changed, or why it is this way
    rather than another** -- it belongs in the commit message, where
    `git blame` will surface it beside the line it explains.

  - **It names the method in one line** -- that is the fold header
    the method already carries:

    ```
    # do_thing - one line saying what it does {{{
    sub do_thing {
    ```

  - **It explains a block of code that is dense or not obvious** --
    a comment block directly before that code, at most two lines.

  - **It flags a branch or step a reader would otherwise misread** --
    a flow-control comment, one line or end-of-line, used sparingly.

  - **It points a later developer at a concern the code still
    carries** -- a marker block led by `TODO`, `FIXME`, `REFACTOR`,
    or `RISK`.  These are the one exception to the two-line limit and
    may run as long as the concern needs.  They are how work still to
    be done is tracked in the one place every reader of the code can
    see, so a marker names something to fix; prose that explains the
    code as it stands does not become a marker by being given one.

Two consequences follow.  A comment above a method that reads as a
description of the method is the POD entry written in the wrong place.
A comment that begins with "because" or "so that" is a commit message
written in the wrong place.

Prefer a Wider Method to a New One
----------------------------------

Before adding a method, look for the one that nearly does the job.  A
sibling that repeats an existing loop to add one condition is a second
reader that will drift from the first; the condition is usually an
option on the method that already exists.  A helper with one caller
belongs inline.  An option nothing calls is deleted, not documented.

Every method costs its `=head2` before it is written, so a new method
is never the cheap choice; make it earn its place.
