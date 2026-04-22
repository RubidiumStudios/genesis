package Genesis::CI::Propagation;

use strict;
use warnings;

# compute_propagation_targets - determine which envs receive files directly {{{
#
# Pure function: no git, no IO.  Given a DAG topology and per-env diff
# data, returns which environments are direct entry points for propagation
# and which files each receives.
#
# An environment is a direct entry point if:
#   1. It has changed files (diff is non-empty)
#   2. NONE of its changed files overlap with any ancestor's changed files
#
# If there is overlap, the env is blocked — it must wait for its ancestor
# to deploy and cascade.  This ensures commits travel as a unit through
# the chain.
#
# Args (named):
#   dag_order   => \@ordered_env_names   (topologically sorted)
#   parent_of   => \%parent_map          (env => parent_env or undef)
#   env_changed => \%changed_files       (env => \@files that differ)
#   scope       => \@scoped_env_names    (optional: subset to consider;
#                                         defaults to dag_order)
#
# Returns: hashref  { env_name => \@files_to_propagate }
#          Only entry point envs appear in the result.
sub compute_propagation_targets {
	my (%args) = @_;

	my @dag_order   = @{$args{dag_order}   || []};
	my %parent_of   = %{$args{parent_of}   || {}};
	my %env_changed = %{$args{env_changed} || {}};
	my @scope       = @{$args{scope}       || \@dag_order};

	# Build a set for fast scope membership check
	my %in_scope = map { $_ => 1 } @scope;

	my %targets;

	for my $env_name (@scope) {
		next unless $env_changed{$env_name};
		next unless @{$env_changed{$env_name}};

		my %my_files = map { $_ => 1 } @{$env_changed{$env_name}};

		# Walk up the DAG checking for overlap with any ancestor
		my $has_ancestor_overlap = 0;
		my $ancestor = $parent_of{$env_name};
		while ($ancestor) {
			if ($env_changed{$ancestor} && @{$env_changed{$ancestor}}) {
				for my $f (@{$env_changed{$ancestor}}) {
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
