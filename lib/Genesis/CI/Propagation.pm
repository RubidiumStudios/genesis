package Genesis::CI::Propagation;

use strict;
use warnings;

# compute_propagation_targets - determine which envs receive files directly {{{
#
# Pure function: no git, no IO.  Given a DAG topology, per-env
# propagation diffs, and (optionally) per-env deploy diffs, returns
# which environments are direct entry points for propagation and
# which files each receives.
#
# Two diffs per env:
#   - propagation_diff: files on control HEAD that aren't yet on this
#     env's branch.  Used to decide what to copy when the env is an
#     entry point.
#   - deploy_diff: files on control HEAD that haven't yet been
#     DEPLOYED from this env (branch may have them, but exodus
#     audit shows an older commit).  Used to detect ancestors that
#     have in-flight propagations — descendants must wait.
#
# An environment is a direct entry point when:
#   1. Its propagation_diff is non-empty, AND
#   2. NONE of its propagation_diff files overlap with any ancestor's
#      deploy_diff (i.e., no ancestor is sitting on an undeployed copy
#      of the same file).
#
# This keeps commits travelling as a unit: a file can't cascade past
# an ancestor that has received it on-branch but not yet deployed it.
#
# When deploy_diff is omitted, it falls back to propagation_diff —
# preserving the original single-diff behaviour for callers that
# aren't yet deployment-aware.
#
# Args (named):
#   dag_order         => \@ordered_env_names   (topologically sorted)
#   parent_of         => \%parent_map          (env => parent_env or undef)
#   env_changed       => \%propagation_diff    (env => \@files to copy)
#   env_undeployed    => \%deploy_diff         (env => \@files pending deploy)
#                                               (optional; defaults to env_changed)
#   scope             => \@scoped_env_names    (optional: subset to consider)
#
# Returns: hashref  { env_name => \@files_to_propagate }
#          Only entry point envs appear in the result.
sub compute_propagation_targets {
	my (%args) = @_;

	my @dag_order      = @{$args{dag_order}      || []};
	my %parent_of      = %{$args{parent_of}      || {}};
	my %env_changed    = %{$args{env_changed}    || {}};
	my %env_undeployed = %{$args{env_undeployed} || \%env_changed};
	my @scope          = @{$args{scope}          || \@dag_order};

	my %in_scope = map { $_ => 1 } @scope;

	my %targets;

	for my $env_name (@scope) {
		next unless $env_changed{$env_name};
		next unless @{$env_changed{$env_name}};

		my %my_files = map { $_ => 1 } @{$env_changed{$env_name}};

		# Walk up the DAG checking for overlap with any ancestor's
		# undeployed set (what the ancestor is still sitting on).
		my $has_ancestor_overlap = 0;
		my $ancestor = $parent_of{$env_name};
		while ($ancestor) {
			if ($env_undeployed{$ancestor} && @{$env_undeployed{$ancestor}}) {
				for my $f (@{$env_undeployed{$ancestor}}) {
					if ($my_files{$f}) {
						$has_ancestor_overlap = 1;
						last;
					}
				}
			}
			last if $has_ancestor_overlap;
			$ancestor = $parent_of{$ancestor};
		}

		unless ($has_ancestor_overlap) {
			$targets{$env_name} = $env_changed{$env_name};
		}
	}

	return \%targets;
}

# }}}

1;
