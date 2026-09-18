package Genesis::CI::Propagation;

use strict;
use warnings;

use Genesis::CI::Marker;

# _apply_propagation_commit - apply files + commit (current branch is target) {{{
sub _apply_propagation_commit {
	my ($git, $env_name, $control_sha, $control_short, $detail) = @_;
	my @to_copy = @{$detail->{changed} || []};
	my @to_rm   = @{$detail->{deleted} || []};
	$git->checkout_file($control_sha, $_) for @to_copy;
	$git->rm(@to_rm) if @to_rm;
	my $msg = Genesis::CI::Marker::build($control_short, $env_name);
	$git->commit($msg, @to_copy);
}
# }}}

1;
