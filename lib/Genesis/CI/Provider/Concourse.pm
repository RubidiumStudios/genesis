package Genesis::CI::Provider::Concourse;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;
use Genesis::UI;

use constant {
	DEFAULT_TEAM => 'main',
};

### Class Methods {{{

# init - create a new Concourse provider from CLI options {{{
sub init {
	my ($class, %opts) = @_;

	bail("Concourse CI provider requires --ci-target")
		unless $opts{'ci-target'};

	$class->new(
		type     => 'concourse',
		target   => $opts{'ci-target'},
		team     => $opts{'ci-team'} || DEFAULT_TEAM,
		insecure => $opts{'ci-insecure'} ? 1 : 0,
	);
}

# }}}
# new - create a Concourse provider from stored config {{{
sub new {
	my ($class, %config) = @_;
	bless({
		label    => 'Concourse',
		target   => $config{target},
		team     => $config{team}     || DEFAULT_TEAM,
		insecure => $config{insecure} ? 1 : 0,
	}, $class);
}

# }}}
# opts - Getopt::Long spec for Concourse-specific CLI flags {{{
sub opts {
	qw/
		ci-target=s
		ci-team=s
		ci-insecure
	/;
}

# }}}
# opts_help - usage documentation for Concourse options {{{
sub opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'concourse' } @{$config{valid_types} || []};

	<<'EOF';
  CI Provider `concourse`:

    --ci-target <name> (required)
        The Concourse target name (as configured in ~/.flyrc) to use when
        setting the pipeline.  This is the same target you would pass to
        `fly -t <target>`.

    --ci-team <name> (optional, defaults to "main")
        The Concourse team name to set the pipeline on.  Defaults to the
        "main" team if not specified.

    --ci-insecure (optional flag)
        Skip TLS certificate verification when connecting to the Concourse
        server.  Equivalent to fly's --skip-ssl-validation flag.
        Use with caution — only for self-signed or development endpoints.

EOF
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'Concourse' }

# }}}
# check_prereqs - verify fly CLI is installed and meets min version {{{
sub check_prereqs {
	my ($self) = @_;
	my $ok = 1;

	# Require fly in PATH
	chomp(my $fly_path = `which fly 2>/dev/null`);
	unless ($fly_path) {
		error(
			"The Concourse CI provider requires the #C{fly} CLI but it was not ".
			"found in your PATH.\n".
			"  Install it from your Concourse server:\n".
			"    #C{<concourse-url>/api/v1/cli?arch=amd64&platform=<linux|darwin|windows>}\n".
			"  Or log in via the Concourse UI and download fly from the bottom-right icon.",
		);
		return 0;
	}

	# Optional minimum version enforcement
	if (defined $self->{min_fly_version}) {
		my ($ver_out) = run({ stderr => 0 }, 'fly', '--version');
		chomp(my $fly_version = $ver_out // '');
		$fly_version =~ s/\s.*$//;  # strip trailing build info if any
		unless (new_enough($fly_version, $self->{min_fly_version})) {
			error(
				"Concourse CI provider requires fly version #C{%s} or later ".
				"(found: #Y{%s}).\n".
				"  Sync fly with your Concourse server: #C{fly -t <target> sync}",
				$self->{min_fly_version},
				$fly_version || 'unknown',
			);
			$ok = 0;
		}
	}

	return $ok;
}

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	my %cfg = (type => 'concourse');
	$cfg{target}   = $self->{target}   if defined $self->{target};
	$cfg{team}     = $self->{team}     if defined $self->{team} && $self->{team} ne DEFAULT_TEAM;
	$cfg{insecure} = 1                 if $self->{insecure};
	return %cfg;
}

# }}}
# interactive_wizard - prompt user for Concourse configuration {{{
sub interactive_wizard {
	my ($self, $top) = @_;

	my $target = prompt_for_line(undef,
		"Concourse target name (from ~/.flyrc): ", '');
	bail("Concourse CI provider requires a target name")
		unless $target && $target =~ /\S/;

	my $team = prompt_for_line(undef,
		sprintf("Concourse team [%s]: ", DEFAULT_TEAM), DEFAULT_TEAM);
	$team = DEFAULT_TEAM unless $team && $team =~ /\S/;

	my $insecure = prompt_for_boolean(
		"Skip TLS certificate verification? [y|n] ", 0);

	return $self->new(
		type     => 'concourse',
		target   => $target,
		team     => $team,
		insecure => $insecure ? 1 : 0,
	);
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider::Concourse - Concourse CI provider for Genesis repo-init

=head1 DESCRIPTION

Manages Concourse-specific CI configuration in .genesis/config ci.provider.

=head1 SYNOPSIS

  my $p = Genesis::CI::Provider::Concourse->init(
    'ci-target'   => 'prod',
    'ci-team'     => 'platform',
    'ci-insecure' => 0,
  );
  my %cfg = $p->config;
  # { type => 'concourse', target => 'prod', team => 'platform' }

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
