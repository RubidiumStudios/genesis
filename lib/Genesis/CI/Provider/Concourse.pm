package Genesis::CI::Provider::Concourse;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;
use Genesis::Config;
use Genesis::UI;

use POSIX qw(mktime);

# The one DEFAULT_TEAM, here beside the fragment that declares it as the
# key's default.  The class that emits the pipeline kept a second copy
# and fell back to it when it compiled, and a comment above each asked a
# reader to keep the two in step, which is a rule nothing enforced.  It
# resolves the team through the fragment below now.
use constant {
	DEFAULT_TEAM => 'main',
};

### Class Methods {{{

# init - create a new Concourse provider from CLI options {{{
#
# Two modes:
#   1. Existing target: --ci-target <name> (looks up url/team/insecure
#      from ~/.flyrc)
#   2. New target: --ci-url <url> --ci-team <team> [--ci-insecure]
#      [--ci-target <name>]  (derives target name if not specified)
#
sub init {
	my ($class, %opts) = @_;

	my $has_target = $opts{'ci-target'};
	my $has_new    = $opts{'ci-url'} || $opts{'ci-team'} || $opts{'ci-insecure'};

	if ($has_target) {
		# Check if the target already exists in flyrc
		my $flyrc = "$ENV{HOME}/.flyrc";
		my $entry;
		if (-f $flyrc) {
			my $data = load_yaml_file($flyrc);
			$entry = $data->{targets}{$opts{'ci-target'}}
				if ref($data) eq 'HASH' && ref($data->{targets}) eq 'HASH';
		}

		if ($entry) {
			# Existing target, so reject conflicting flags
			bail(
				"Target '%s' already exists in ~/.flyrc.\n".
				"  Cannot combine --ci-target with --ci-url, --ci-team, ".
				"or --ci-insecure when the target already exists.",
				$opts{'ci-target'}
			) if $has_new;

			return $class->new(
				type     => 'concourse',
				target   => $opts{'ci-target'},
				url      => $entry->{api},
				team     => $entry->{team} || DEFAULT_TEAM,
				insecure => $entry->{insecure} ? 1 : 0,
			);
		}

		# Target name provided but does not exist yet, so fall through
		# to new-target creation below (--ci-url and --ci-team required)
	}

	# New target: --ci-url and --ci-team are required; --ci-target is
	# an optional name override (derived from url/team if omitted).
	bail(
		"Concourse CI provider requires --ci-target (existing fly target) ".
		"or --ci-url and --ci-team (new target)"
	) unless $opts{'ci-url'} && $opts{'ci-team'};

	my $target = $opts{'ci-target'}
		// _derive_target_name($opts{'ci-url'}, $opts{'ci-team'});

	return $class->new(
		type     => 'concourse',
		target   => $target,
		url      => $opts{'ci-url'},
		team     => $opts{'ci-team'},
		insecure => $opts{'ci-insecure'} ? 1 : 0,
	);
}

# }}}
# new - create a Concourse provider from stored config {{{
sub new {
	my ($class, %config) = @_;
	$class = ref($class) || $class;
	bless({
		label           => 'Concourse',
		type            => $config{type} || 'concourse',
		target          => $config{target},
		url             => $config{url},
		team            => $config{team}            || DEFAULT_TEAM,
		insecure        => $config{insecure}        ? 1 : 0,
		min_fly_version => $config{min_fly_version} || undef,
		fly_bin_path    => $config{fly_bin_path}    || undef,
	}, $class);
}

# }}}
# fly_command - the fly this provider runs {{{
#
# One home for the name, so the prerequisites check, the login, and the
# targets read all run the same binary.  A session names one through
# GENESIS_FLY_BIN and wins, because an override the operator sets for one
# run should beat the repository's default; the repository names one through
# pipeline.provider.fly_bin_path, so two repositories on two Concourse
# installations each keep the fly that matches theirs; and a repository that
# names none wants whatever fly the path finds.  The class answers too,
# from the environment alone, for a caller that holds no provider yet.
sub fly_command {
	my ($self) = @_;
	return $ENV{GENESIS_FLY_BIN} || (ref($self) && $self->{fly_bin_path}) || 'fly';
}

# }}}
# fly - run one fly command with the flags this provider's answers imply {{{
#
# Every fly this provider runs goes through here, so the binary is the one
# fly_command names and -k follows the insecure setting in one place.  A
# target is named only where the caller hands one, because fly --version
# and fly targets take none.  The arguments reach bash as a list and never
# as a string, so a path with a space in it and a team an operator named
# both survive.  A leading hashref carries run's own options, plus target
# and insecure for the caller that knows better than the object, which is
# the wizard before its answers are stored.
sub fly {
	my ($self, @args) = @_;
	my %opts     = %{ref($args[0]) eq 'HASH' ? shift @args : {}};
	my $target   = delete $opts{target};
	my $insecure = exists $opts{insecure} ? delete $opts{insecure} : $self->{insecure};
	return run(\%opts, '"$@"',
		$self->fly_command,
		($insecure ? ('-k') : ()),
		(defined $target ? ('-t', $target) : ()),
		@args);
}

# }}}
# check_prereqs - verify fly CLI is present and meets min version {{{
sub check_prereqs {
	my ($self) = @_;

	my $fly = $self->fly_command;
	my ($fly_path) = run({ stderr => 0 }, 'type -p "$1"', $fly);
	chomp($fly_path //= '');
	unless ($fly_path) {
		error(
			"Concourse CI provider requires the #C{%s} CLI but it was not found in PATH.\n".
			"  Download it from your Concourse server's home page or:\n".
			"    #C{<concourse-url>/api/v1/cli?arch=amd64&platform=<linux|darwin|windows>}",
			$fly
		);
		return 0;
	}

	if ($self->{min_fly_version}) {
		my ($ver_out) = $self->fly({ stderr => 0 }, '--version');
		chomp($ver_out //= '');

		# A floor that cannot be compared against is a floor that is not
		# enforced, and a check that carried on past an unreadable
		# version line enforced nothing while saying nothing either.  So
		# the refusal names what it read instead.
		unless (semver($ver_out)) {
			error(
				"Concourse CI provider could not read a fly version from ".
				"#C{%s --version}, which said #C{%s}.\n".
				"  This pipeline declares a minimum of #C{%s}, and a ".
				"version that cannot be read cannot be checked against it.",
				$fly, ($ver_out eq '' ? '(nothing)' : $ver_out),
				$self->{min_fly_version}
			);
			return 0;
		}

		# One comparison, and it is the one the rest of Genesis uses.
		# A hand-rolled split read a leading v as a major number of
		# zero, so every fly on earth cleared a floor written v7.9.0,
		# and it warned about a non-numeric string on the way past.  It
		# had nothing to say about a release candidate either.
		unless (new_enough($ver_out, $self->{min_fly_version})) {
			error(
				"Concourse CI provider requires fly >= %s but found %s.\n".
				"  Upgrade fly from your Concourse server.",
				$self->{min_fly_version}, $ver_out
			);
			return 0;
		}
	}

	return 1;
}

# }}}
# opts - Getopt::Long spec for Concourse-specific CLI flags {{{
sub opts {
	qw/
		ci-target=s
		ci-url=s
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

    Use an existing fly target:

    --ci-target <name>
        An existing Concourse target name from ~/.flyrc.  URL, team, and
        TLS settings are read from the target.  Cannot be combined with
        --ci-url, --ci-team, or --ci-insecure when the target exists.

    Or specify a new target:

    --ci-url <url> (required for new targets)
        The Concourse server URL (e.g. https://ci.example.com).

    --ci-team <name> (required for new targets)
        The Concourse team name.

    --ci-target <name> (optional for new targets)
        Override the fly target name.  Defaults to a name derived from
        the URL and team (e.g. ci/platform).

    --ci-insecure (optional flag)
        Skip TLS certificate verification when connecting to the Concourse
        server.  Equivalent to fly's --skip-ssl-validation flag.

    When neither --ci-target nor --ci-url is provided, an interactive
    wizard guides target selection or creation.

EOF
}

# }}}
# provider_options_schema - schema for pipeline.provider: when type=concourse {{{
#
# Keys map directly to the pipeline.provider: sub-keys in .genesis/config.
# This fragment is the only place these keys are declared, and it is the
# whole of what the block admits beside the type, so a key that is not
# here is refused by name as the configuration loads.  That is why target,
# url, team and insecure live here rather than beside the type, where they
# sat unread under every other provider.
#
# There is no output_layout here.  Concourse emits one pipeline definition
# and declares multi_file_output false, and a provider offers that key by
# declaring it, so the provider that cannot use it declares nothing and an
# operator who writes it is refused like anybody writing a key nobody
# declared.
#
# pipeline_name is gone, because pipeline.name is the one label the
# compiler and the status commands read, and expose is public with no
# alias behind it.
#
# NOTE: notification styles, BOSH upgrade locks, and task library are
# configuration-level features rather than provider-level options, and
# they are documented in the compiler class's cli_opts_help and POD.
sub provider_options_schema {
	return {
		# Declared to be refused by name, with what replaces it (D86).
		target   => {type => 'string',  check => \&_target_retired, description => 'Retired: each operator resolves their own fly target'},
		url      => {type => 'string',  required => \&_pipeline_enabled, description => 'Concourse API URL, used by fly login'},
		team     => {type => 'string',  required => \&_pipeline_enabled, description => 'Concourse team name'},
		insecure => {type => 'boolean', default => Genesis::Config::FALSE, description => 'Skip TLS certificate verification'},

		# The floor check_prereqs enforces, declared so that a
		# repository can set it.  It was readable on the object and
		# settable only from Perl, so an operator who wrote the key was
		# refused by name and the version check had nothing to enforce.
		# There is no default, because a repository that names no floor
		# wants any fly that is present, which is what the check does
		# when the key is absent.
		#
		# Declared as a version rather than as a string, so a value the
		# check cannot compare against is refused as the configuration
		# loads rather than silently enforcing nothing later.  A leading
		# v is admitted here and stripped before the comparison, because
		# that is how a Concourse release names itself.
		min_fly_version => {type => 'semver', description => 'Lowest fly version this pipeline may be set with'},

		# The fly this repository runs, so two repositories on two Concourse
		# installations each keep the one that matches theirs.  A session
		# overrides it through GENESIS_FLY_BIN, and a repository that names
		# none takes whatever fly the path finds; fly_command is the one
		# reader of all three.
		fly_bin_path    => {type => 'string', description => 'Path or name of the fly CLI this pipeline is set with; GENESIS_FLY_BIN overrides it'},

		public   => {type => 'boolean', default => Genesis::Config::FALSE, description => 'Make build logs publicly viewable'},
		tagged   => {type => 'boolean', default => Genesis::Config::FALSE, description => "Pin each environment's containers to workers tagged with its name"},

		# The block defaults to an empty hash for the same reason the
		# provider block itself does: validation only walks into a hash
		# that is present, so without it the two defaults below are never
		# reached and never resolve.
		task     => {
			type        => 'hash',
			default     => {},
			description => 'The image every emitted task runs in',
			schema => {
				image   => {type => 'string', default => 'genesiscommunity/concourse', description => 'Task image repository'},
				version => {type => 'string', default => 'latest', description => 'Task image tag'},

				# ASTBuilder and PipelineDescriptor both read
				# task.privileged as the list of environments whose deploy
				# task runs privileged, so the key has to be declared here
				# or an operator who writes it has the load refuse it by
				# name.  No default, because an absent list and an empty
				# one mean the same thing to the readers.
				privileged => {
					type        => 'array',
					subtype     => 'string',
					envsplit    => ',',
					description => "Environments whose deploy task runs privileged",
				},
			}
		},

		pause_after_set => {type => 'boolean', default => Genesis::Config::FALSE, description => 'Leave the pipeline paused after fly set-pipeline'},
		group_commits   => {type => 'boolean', default => Genesis::Config::TRUE, description => 'Deploy the tip of what arrived rather than each commit in turn'},
	};
}

# }}}
# capabilities - Concourse can do all but multi-file output {{{
#
# The six capability names, declared beside the fragment above, because
# one class answers for both halves of a provider and the gates read this
# from the class the provider map already names.
sub capabilities {
	return {
		deployment_locks      => 1,  # the locker resource
		cross_pipeline_events => 1,  # the shuttle's request queue and _ran event
		optional_git_triggers => 1,  # trigger: false on a get
		scheduled_jobs        => 1,  # the time resource
		per_commit_runs       => 1,  # version: every
		multi_file_output     => 0,  # one pipeline definition, and no more
	};
}

# }}}
# validate_config - a url that is one {{{
#
# The rules a declaration cannot state, on top of the generic pass the
# base gives every block.  SUPER first, because the declaration is the
# floor rather than a subset of what is wanted checked.
sub validate_config {
	my ($class, $config, $path, $discriminator) = @_;
	my @errors = $class->SUPER::validate_config($config, $path, $discriminator);

	my $url = $config->get("$path.url");
	push @errors, "'url' must begin with http:// or https://"
		if $url && $url !~ m{^https?://};
	return @errors;
}

# }}}
# _pipeline_enabled - url and team are required once the pipeline is on {{{
sub _pipeline_enabled {
	my ($siblings, $config) = @_;
	return $config && $config->get('pipeline.enabled') ? 1 : 0;
}

# }}}
# _target_retired - a committed fly target is refused, with what replaces it {{{
sub _target_retired {
	return "is no longer read.  A fly target is an entry in one operator's ".
		"#C{~/.flyrc}, so a committed one means nothing on a teammate's machine.  ".
		"Remove it, and name the Concourse with #C{pipeline.provider.url} and ".
		"#C{pipeline.provider.team}.  Each operator's target is then the one ".
		"#C{--target} names for a run, else the one this clone pins with ".
		"#C{git config genesis.fly-target <target>}, else the one #C{~/.flyrc} ".
		"target whose URL and team are the configuration's.";
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'Concourse' }

# }}}
# team - the Concourse team, read and written {{{
sub team {
	my ($self, $value) = @_;
	$self->{team} = $value if defined $value;
	return $self->{team} // DEFAULT_TEAM;
}

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	# The target is this operator's, so it is never written (D86).
	my %cfg = (type => 'concourse');
	$cfg{url}      = $self->{url}      if defined $self->{url};
	$cfg{team}     = $self->{team}     if defined $self->{team};
	$cfg{insecure} = 1                 if $self->{insecure};
	return %cfg;
}

# }}}
# interactive_wizard - select existing target or create a new one {{{
sub interactive_wizard {
	my ($self, $top) = @_;

	my ($target, $url, $team, $insecure);

	# --- Gather existing targets from fly targets + flyrc ---
	my @fly_targets = $self->_load_fly_targets;

	if (@fly_targets) {
		# Compute column widths for aligned display
		my ($w_name, $w_api, $w_team) = (0, 0, 0);
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

		push @choices, { separator => 1 };
		push @choices, {
			value   => '__new__',
			label   => '#Yi{Create a new Concourse target}',
			summary => '(new target)',
		};

		my $selection = new_prompt_for_choice(
			header      => "Select a Concourse target:",
			choices     => \@choices,
			default     => $self->{target},
			description => "target",
		);

		if ($selection ne '__new__') {
			my ($selected) = grep { $_->{name} eq $selection } @fly_targets;
			$target   = $selected->{name};
			$url      = $selected->{api};
			$team     = $selected->{team};
			$insecure = $selected->{insecure};

			# Re-authenticate if the token has expired
			if ($selected->{expired}) {
				info "\nRe-authenticating expired target #C{%s}...\n", $target;
				$self->fly({ interactive => 1, target => $target, insecure => $insecure,
					  onfailure   => "fly login failed for target '$target'" },
					'login', '-n', $team);
			}
		}
	}

	# Create a new target: prompt for details and run fly login
	unless ($target) {
		$url = prompt_for_line(undef,
			"Concourse URL (e.g. https://ci.example.com): ", '');
		bail("A Concourse URL is required.") unless $url && $url =~ m{^https?://};

		$team = prompt_for_line(undef,
			sprintf("Team name [%s]: ", DEFAULT_TEAM), DEFAULT_TEAM);
		$team = DEFAULT_TEAM unless $team && $team =~ /\S/;

		$insecure = prompt_for_boolean(
			"Skip TLS certificate verification? [y|n] ", 0);

		$target = _derive_target_name($url, $team);

		info "\nLogging in to #C{%s} as team #C{%s} (target: #C{%s})...\n",
			$url, $team, $target;
		$self->fly({ interactive => 1, target => $target, insecure => $insecure,
			  onfailure   => "fly login failed for target '$target'" },
			'login', '-c', $url, '-n', $team);
	}

	return $self->new(
		type     => 'concourse',
		target   => $target,
		url      => $url,
		team     => $team,
		insecure => $insecure ? 1 : 0,
	);
}

# }}}

# _load_fly_targets - merge fly targets output with flyrc insecure flags {{{
sub _load_fly_targets {
	my ($self) = @_;
	my @targets;

	my $flyrc = "$ENV{HOME}/.flyrc";
	my %flyrc_data;
	if (-f $flyrc) {
		my $data = load_yaml_file($flyrc);
		if (ref($data) eq 'HASH' && ref($data->{targets}) eq 'HASH') {
			%flyrc_data = %{$data->{targets}};
		}
	}

	my ($fly_out) = $self->fly({ stderr => '/dev/null', insecure => 0 },
		'targets', '--print-table-headers');
	if ($fly_out && $fly_out =~ /\S/) {
		my @lines = split /\n/, $fly_out;
		my @rows = parse_fixed_width_table(@lines);
		for my $row (@rows) {
			my $name = $row->{name} // next;
			my $flyrc_entry = $flyrc_data{$name} // {};
			push @targets, {
				name     => $name,
				api      => $row->{url}  // '(unknown)',
				team     => $row->{team} // DEFAULT_TEAM,
				insecure => $flyrc_entry->{insecure} ? 1 : 0,
				expired  => _token_expired($row->{expiry}),
			};
		}
	}
	return @targets;
}

# }}}
# _derive_target_name - build a target name from url and team {{{
sub _derive_target_name {
	my ($url, $team) = @_;
	# https://ci.example.com → ci
	# https://pipes.scalecf.net → pipes
	(my $host = $url) =~ s{^https?://}{}; $host =~ s{[:/].*}{};
	my $subdomain = (split /\./, $host)[0] // $host;
	return $team eq DEFAULT_TEAM ? $subdomain : "$subdomain/$team";
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

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
