package Genesis::CI::Provider::GithubActions;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;
use Genesis::UI;

use constant {
	DEFAULT_BRANCH => 'main',
};

### Class Methods {{{

# init - create a new GithubActions provider from CLI options {{{
sub init {
	my ($class, %opts) = @_;

	bail("GitHub Actions CI provider requires --ci-github-repo (format: org/repo)")
		unless $opts{'ci-github-repo'};

	bail("--ci-github-repo must be in 'org/repo' format")
		unless $opts{'ci-github-repo'} =~ m{^[^/]+/[^/]+$};

	$class->new(
		type   => 'github-actions',
		repo   => $opts{'ci-github-repo'},
		branch => $opts{'ci-github-branch'} || DEFAULT_BRANCH,
	);
}

# }}}
# new - create a GithubActions provider from stored config {{{
sub new {
	my ($class, %config) = @_;
	bless({
		label  => 'GitHub Actions',
		type   => $config{type} || 'github-actions',
		repo   => $config{repo},
		branch => $config{branch} || DEFAULT_BRANCH,
	}, $class);
}

# }}}
# opts - Getopt::Long spec for GitHub Actions-specific CLI flags {{{
sub opts {
	qw/
		ci-github-repo=s
		ci-github-branch=s
	/;
}

# }}}
# opts_help - usage documentation for GitHub Actions options {{{
sub opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'github-actions' } @{$config{valid_types} || []};

	<<'EOF';
  CI Provider `github-actions`:

    --ci-github-repo <org/repo> (required)
        The GitHub repository to configure workflows for, in "org/repo"
        format (e.g. "myorg/my-deployment-repo").

    --ci-github-branch <branch> (optional, defaults to "main")
        The branch that workflow dispatch events and pushes will trigger
        pipeline runs on.  Defaults to "main".

EOF
}

# }}}
# capabilities - what a workflow can do today {{{
#
# GitHub Actions declares multi_file_output true, because a workflow
# directory is several files and the override file name follows them.
# The other five are left to be read off the provider when its compiler
# class is written, so they are false here and the refusal is the
# conservative one.  A key this provider cannot honour is refused now
# rather than accepted and dropped when the pipeline is emitted.
sub capabilities {
	return {multi_file_output => 1,
		map {($_ => 0)} qw/cross_pipeline_events deployment_locks
			optional_git_triggers per_commit_runs scheduled_jobs/};
}

# }}}
# provider_options_schema - the one key a workflow offers {{{
#
# Empty until now, because this provider's two CLI flags moved to the
# source-control block.  The provider that can emit several files is the
# provider that declares the key choosing between the forms, so
# declaring multi_file_output above means declaring this.
sub provider_options_schema {
	return {
		output_layout => {
			type        => 'enum',
			values      => [qw/single multiple/],
			default     => 'single',
			description => 'Whether the override file is named per emitted file'
		},
	};
}

# }}}
# why this provider states no rule of its own {{{
#
# Nothing is written here, so the base's default is what runs, and that
# validates the block against the fragment above and refuses anything
# else by name.  With an empty fragment that means no provider key is
# admitted beside this type at all, which is the whole of what this
# provider has to say about its block today.
#
# The two rules that stood here both spoke of repo.  The repository a
# pipeline acts on lives in pipeline.source_control.repository rather
# than in the provider block, so the fragment declares no such key and
# an operator has nowhere to write one.  They worked only because the
# caller resolved the source control first and handed the value in, and
# the dispatch now runs before any of that is derived.
# Genesis::Top::_source_control already refuses a pipeline whose
# repository cannot be named, in the operator's own terms, so nothing an
# operator relied on is lost with them.
# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'GitHub Actions' }

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	my %cfg = (type => 'github-actions');
	$cfg{repo}   = $self->{repo}   if defined $self->{repo};
	$cfg{branch} = $self->{branch} if defined $self->{branch} && $self->{branch} ne DEFAULT_BRANCH;
	return %cfg;
}

# }}}
# interactive_wizard - prompt user for GitHub Actions configuration {{{
sub interactive_wizard {
	my ($self, $top, %opts) = @_;

	my $repo = $opts{'ci-github-repo'};
	unless ($repo && $repo =~ m{^[^/]+/[^/]+$}) {
		$repo = prompt_for_line(undef,
			"GitHub repository (org/repo format): ", '');
		bail("GitHub Actions CI provider requires a repository")
			unless $repo && $repo =~ /\S/;
		bail("Repository must be in 'org/repo' format")
			unless $repo =~ m{^[^/]+/[^/]+$};
	}

	my $branch;
	if (exists $opts{'ci-github-branch'}) {
		$branch = $opts{'ci-github-branch'} || DEFAULT_BRANCH;
	} else {
		$branch = prompt_for_line(undef,
			sprintf("Default branch [%s]: ", DEFAULT_BRANCH), DEFAULT_BRANCH);
		$branch = DEFAULT_BRANCH unless $branch && $branch =~ /\S/;
	}

	return $self->new(
		type   => 'github-actions',
		repo   => $repo,
		branch => $branch,
	);
}

# }}}
# }}}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
