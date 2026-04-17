package Genesis::CI::Provider::Concourse;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;
use Genesis::UI;

use POSIX qw(mktime);

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
	my ($fly_path) = run({ stderr => 0 }, 'type -p fly');
	chomp($fly_path //= '');
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
	my ($self, $top, %opts) = @_;

	my ($target, $team, $insecure);

	my @fly_targets;
	my $flyrc = "$ENV{HOME}/.flyrc";
	my %flyrc_data;
	if (-f $flyrc) {
		my $data = load_yaml_file($flyrc);
		if (ref($data) eq 'HASH' && ref($data->{targets}) eq 'HASH') {
			%flyrc_data = %{$data->{targets}};
		}
	}

	my ($fly_out) = run({ stderr => '/dev/null' },
		'fly targets --print-table-headers');
	if ($fly_out && $fly_out =~ /\S/) {
		my @lines = split /\n/, $fly_out;
		my @rows = parse_fixed_width_table(@lines);
		for my $row (@rows) {
			my $name = $row->{name} // next;
			my $flyrc_entry = $flyrc_data{$name} // {};
			push @fly_targets, {
				name     => $name,
				api      => $row->{url}  // '(unknown)',
				team     => $row->{team} // DEFAULT_TEAM,
				insecure => $flyrc_entry->{insecure} ? 1 : 0,
				expired  => _token_expired($row->{expiry}),
			};
		}
	}

	if (@fly_targets) {
		# Compute column widths for aligned display
		my $w_name = 0;
		my $w_api  = 0;
		my $w_team = 0;
		for (@fly_targets) {
			$w_name = length($_->{name}) if length($_->{name}) > $w_name;
			$w_api  = length($_->{api})  if length($_->{api})  > $w_api;
			$w_team = length($_->{team}) if length($_->{team}) > $w_team;
		}

		my @choices = map {{
			value   => $_->{name},
			label   => sprintf("#C{%-${w_name}s}  %-${w_api}s  %-${w_team}s  %s%s",
				$_->{name}, $_->{api}, $_->{team},
				$_->{insecure} ? "#Yi{insecure}" : "#G{secure}  ",
				$_->{expired}  ? "  #R{EXPIRED!}" : ""),
			summary => $_->{name},
		}} @fly_targets;

		# Separator + "create new" option at the bottom
		push @choices, { separator => 1 };
		push @choices, {
			value   => '__new__',
			label   => '#Yi{Create a new Concourse target}',
			summary => '(new target)',
		};

		$target = new_prompt_for_choice(
			header      => "Select a Concourse target:",
			choices     => \@choices,
			default     => $self->{target},
			description => "target",
		);

		if ($target ne '__new__') {
			# Pre-fill team and insecure from the selected flyrc entry
			my ($selected) = grep { $_->{name} eq $target } @fly_targets;
			if ($selected) {
				$team     = $selected->{team};
				$insecure = $selected->{insecure};
			}
		}
	}

	# Create a new target: prompt for details and run fly login
	if (!$target || $target eq '__new__') {
		my $name = prompt_for_line(undef,
			"Target name (short alias for this Concourse): ", '');
		bail("A target name is required.") unless $name && $name =~ /\S/;

		my $url = prompt_for_line(undef,
			"Concourse URL (e.g. https://ci.example.com): ", '');
		bail("A Concourse URL is required.") unless $url && $url =~ m{^https?://};

		$team = prompt_for_line(undef,
			sprintf("Team name [%s]: ", DEFAULT_TEAM), DEFAULT_TEAM);
		$team = DEFAULT_TEAM unless $team && $team =~ /\S/;

		$insecure = prompt_for_boolean(
			"Skip TLS certificate verification? [y|n] ", 0);

		# Run fly login to create the target in ~/.flyrc and
		# authenticate the user.  This is interactive — fly will
		# prompt for credentials or open a browser.
		info "\nLogging in to Concourse as #C{%s} on #C{%s}...\n", $team, $url;
		my @fly_cmd = ('fly', '-t', $name, 'login',
			'-c', $url, '-n', $team);
		push @fly_cmd, '-k' if $insecure;
		run({ interactive => 1,
			  onfailure   => "fly login failed for target '$name'" },
			join(' ', map { /\s/ ? "\"$_\"" : $_ } @fly_cmd));

		$target = $name;
	}

	return (ref($self) || $self)->new(
		type     => 'concourse',
		target   => $target,
		team     => $team,
		insecure => $insecure,
	);
}

# }}}

# _token_expired - check if a fly targets expiry string is in the past {{{
my %_months = (
	Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4,  Jun => 5,
	Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11,
);
sub _token_expired {
	my ($expiry_str) = @_;
	return 0 unless $expiry_str && $expiry_str =~ /\S/;

	# fly targets format: "Sat, 08 Feb 2025 18:53:16 UTC"
	if ($expiry_str =~ /(\d{2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+UTC/) {
		my ($day, $mon, $year, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
		return 0 unless defined $_months{$mon};
		my $exp = eval {
			local $ENV{TZ} = 'UTC';
			POSIX::mktime($sec, $min, $hour, $day, $_months{$mon}, $year - 1900);
		};
		return 0 unless $exp;
		return $exp < time() ? 1 : 0;
	}
	return 0;
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
