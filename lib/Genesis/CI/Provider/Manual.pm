package Genesis::CI::Provider::Manual;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;

### Class Methods {{{

# init - create a Manual provider (no options needed) {{{
sub init {
	my ($class, %opts) = @_;
	$class->new(type => 'manual');
}

# }}}
# new - create a Manual provider {{{
sub new {
	my ($class, %config) = @_;
	bless({ label => 'Manual' }, $class);
}

# }}}
# opts_help - usage documentation for Manual provider {{{
sub opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'manual' } @{$config{valid_types} || []};

	<<'EOF';
  CI Provider `manual`:

    This provider type disables automated pipeline management.  Genesis
    will scaffold the repository structure but no CI system will be
    automatically configured.  Use this when you manage your pipeline
    entirely outside of Genesis or through a separate process.

    No additional options are required.

EOF
}

# }}}
# provider_options_schema - manual reads no key of its own {{{
#
# Empty rather than absent, under D105.  The refusal D100 asks for falls
# out of it: a provider key written beside type: manual is a key nothing
# declares, so it is refused by name like any other undeclared key, and
# manual needs no special case to get there.
sub provider_options_schema {
	return {};
}

# }}}
# capabilities - a manual pipeline can do none of the six {{{
#
# D101's declaration, answered honestly.  Manual runs no jobs at all, so
# every ability is false and every key one of them gates is refused at
# load naming both, which is better than the block standing aside because
# there was nothing to read.
sub capabilities {
	return {map {($_ => 0)} qw/cross_pipeline_events deployment_locks
		multi_file_output optional_git_triggers per_commit_runs
		scheduled_jobs/};
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'Manual' }

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	return (type => 'manual');
}

# }}}
# interactive_wizard - no prompts needed for Manual {{{
sub interactive_wizard {
	my ($self, $top) = @_;
	return $self->new(type => 'manual');
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider::Manual - Manual (no-automation) CI provider for Genesis repo-init

=head1 DESCRIPTION

A no-op CI provider for repositories that manage their pipelines manually.
Takes no additional options and stores only C<< type => 'manual' >> in config.

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
