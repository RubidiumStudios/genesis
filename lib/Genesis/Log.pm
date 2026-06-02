package Genesis::Log;
use v5.20;
use warnings;

use utf8;
binmode STDOUT, 'utf8';
binmode STDERR, 'utf8';

#use open ':encoding(utf-8)';

use Genesis::State;
use Genesis::Term;

use POSIX qw/strftime/;
use Cwd ();
use File::Basename qw/dirname/;
use File::Spec;
#use Symbol qw/qualify_to_ref/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use Time::Seconds;

use base 'Exporter';
our @EXPORT = qw/
	$Logger
	find_log_level
	meets_level
	get_stack
	get_scope
	log_levels
	log_styles
/;

sub new {
	my ($class) = @_;
	my $hostname =  (`type -p hostname &>/dev/null`)
		? `hostname | cut -f 1 -d.`
		: 'localhost';
	chomp(my $user = `whoami`);
	$Genesis::Log::Logger //= bless({
		buffer => [],
		logs => {},
		log_templates => {},
		realized_logs => {},
		command_logged => {},
		user => $user,
		hostname => $hostname,
		pid => $$,
		capture_stack_min_level => 2,
		version => ($Genesis::VERSION eq "(development)")
			? "0.0.0-rc.0"
			: $Genesis::VERSION #FIXME - include dirty indicator
	}, $class);
	return $Genesis::Log::Logger;
}

sub configure_log {
	my $self = shift;
	my $log = (scalar(@_) % 2) ? shift : '<terminal>';
	my %options = @_;
	my @valid_levels = qw/ERROR WARN DEBUG INFO TRACE/;
	my ($level_ord, $level);
	my $default_level = envset("QUIET") ? "ERROR" :  envset("GENESIS_TRACE") ? "TRACE" : envset("GENESIS_DEBUG") ? "DEBUG" : "INFO";
	my $default_output_style = (defined($Genesis::RC) && $Genesis::RC->loaded) ? $Genesis::RC->get('output_style','plain') : 'plain';

	# Store template if log path contains template variables
	if ($log && $log ne '<terminal>' && $log =~ /\{(command|timestamp|date|time|pid|env)\}/) {
		# Skip logging for certain commands
		my $skip_commands = $options{skip_commands} || [];
		push @$skip_commands, 'help' unless grep { $_ eq 'help' } @$skip_commands;

		$self->{log_templates}{$log} = {
			template => $log,
			options => \%options,
			skip_commands => $skip_commands
		};
		return $self;
	}

	# Create log directory if it doesn't exist.
	if ($log && $log ne '<terminal>') {
		require Genesis;
		my $dir = dirname(File::Spec->rel2abs(Genesis::expand_path($log)));
		if (!-d $dir) {
			printf STDERR wrap( # Have to use printf because logs aren't set up yet
				csprintf(
					"[[#BK{[#E{%s}NOTICE]} >>Creating missing log directory for log #c{%s}\n\n",
					(defined($Genesis::RC) && $Genesis::RC->loaded && $Genesis::RC->get('output_style','plain') eq 'fun') ? 'megaphone' : '',
					$log
				),
				terminal_width
			);
			Genesis::mkdir_or_fail $dir
		}
	}

	unless ($self->{logs}{$log}) {
		$self->{logs}{$log} = {
			level       => $default_level,
			level_ord   => level_ord($default_level),
			show_stack  => 'none',
			timestamp   => ($log eq '<terminal>' ? 0 : 1),
			next_entry  =>  0,
			style       => $ENV{GENESIS_LOG_STYLE}//$default_output_style
		}
	}
	if ($options{level}) {
		$level = find_log_level($options{level});
		$self->{logs}{$log}{level} = $level; ;
		$self->{logs}{$log}{level_ord} = level_ord($level);
	}
	$self->{logs}{$log}{show_stack} = $options{show_stack} if defined($options{show_stack});
	$self->{logs}{$log}{timestamp} = $options{timestamp} if defined($options{timestamp});
	$self->{logs}{$log}{next_entry} = scalar(@{$self->{buffer}}) if $options{truncate};
	$self->{logs}{$log}{style} = $options{style} if $options{style};
	$self->{logs}{$log}{no_color} = $options{no_color} if defined($options{no_color});
	$self->{logs}{$log}{no_utf8} = $options{no_utf8} if defined($options{no_utf8});

	# Clean up log, unless in callback or log is STDERR
	unless ($log eq '<terminal>' || in_callback) {
		if (($options{lifespan}//'') eq 'current') {
			(my $file = $log) =~ s/^~/$ENV{HOME}/;
			open my $fh, '>', $file;
			truncate $fh, 0;
			close $fh;
		}
		# TODO: time based truncation
	}
	return $self;
}

sub setup_from_configs {
	my ($class, $log_configs) = @_;

	require Genesis;

	if (ref($log_configs) eq 'ARRAY') {
		for (@$log_configs) {
			my $file = delete($_->{file});
			my $path = delete($_->{path});

			# Handle new format with path and file template
			if ($path && $file) {
				# Expand the base path
				$path = File::Spec->rel2abs(Genesis::expand_path($path));
				# Combine path and file template
				$file = File::Spec->catfile($path, $file);
			} elsif (!$file) {
				# Default file template if not specified
				$file = $path ? File::Spec->catfile($path, '{env}/{command}/{timestamp}.log') : '~/.genesis/last-trace';
			}

			$class->new->configure_log(File::Spec->rel2abs(Genesis::expand_path($file)), %{$_});
			# TODO: add suppress list so that we can set a level, but ingore specific output
			# TODO: support an only-log-if-an-error-occurred setting... that adds and flushes the log in END step if rc > 0
		}
	} else {
		Genesis::bail("Configuration error - logs entry must be an array");
	}
}

# parse_lifespan - parse a lifespan config string into a structured policy.
#
# Pure function: no IO, no globals.  Returns:
#   {
#     mode        => 'none' | 'union' | 'intersection' | 'truncate',
#     count       => N | undef,
#     age_seconds => S | undef,
#     warnings    => [strings],  # caller emits subject to
#                                # suppress_warnings.deprecations
#   }
#
# Bails (Genesis::bail) on unparseable input with the offending substring
# named.
#
# Modes:
#   'none'         - no cleanup pass (value 'forever')
#   'union'        - keep file if EITHER count or age would keep
#                    ('min of ...', bare 'or', bare count, bare duration)
#   'intersection' - keep file only if BOTH count and age would keep
#                    ('max of ...')
#   'truncate'     - reserved; not currently produced (kept for forward
#                    compat with the design doc)
sub parse_lifespan {
	my ($value) = @_;

	Genesis::bail("Invalid lifespan: empty value")
		unless defined($value) && length($value);

	my $v = $value;
	$v =~ s/^\s+|\s+$//g;
	Genesis::bail("Invalid lifespan: empty value")
		unless length($v);

	if (lc($v) eq 'forever') {
		return {
			mode => 'none', count => undef, age_seconds => undef,
			warnings => [],
		};
	}

	if (lc($v) eq 'current') {
		return {
			mode => 'union', count => 1, age_seconds => undef,
			warnings => [
				'lifespan: current is deprecated; '.
				'use lifespan: 1 instead '.
				'(with default on_reuse: truncate for equivalent behavior)',
			],
		};
	}

	# Parse a single bound: bare count (optionally "5 logs") or duration.
	my $parse_bound = sub {
		my ($part) = @_;
		$part =~ s/^\s+|\s+$//g;
		if ($part =~ /^(\d+)\s*(?:logs?)?$/i) {
			return ('count', $1 + 0);
		}
		if ($part =~ /^(\d+)\s*(d|day|days|w|week|weeks|m|mon|month|months|y|year|years)$/i) {
			my ($num, $unit) = ($1, $2);
			my $secs = _time_unit_to_seconds($unit);
			return ('age_seconds', $num * $secs) if $secs;
		}
		return ();
	};

	# Detect compound form: "min of X or Y", "max of X or Y", "X or Y".
	my ($mode, $rest);
	if ($v =~ /^min\s+of\s+(.+)$/i) {
		$mode = 'union';
		$rest = $1;
	} elsif ($v =~ /^max\s+of\s+(.+)$/i) {
		$mode = 'intersection';
		$rest = $1;
	} elsif ($v =~ /\s+or\s+/i) {
		$mode = 'union';
		$rest = $v;
	}

	if (defined $mode) {
		my @parts = split /\s+or\s+/i, $rest;
		Genesis::bail("Invalid lifespan: '%s' (expected '<count> or <duration>')", $value)
			unless @parts == 2;
		my $result = {
			mode => $mode, count => undef, age_seconds => undef,
			warnings => [],
		};
		for my $part (@parts) {
			my ($key, $val) = $parse_bound->($part);
			Genesis::bail("Invalid lifespan component: '%s' in '%s'", $part, $value)
				unless defined $key;
			$result->{$key} = $val;
		}
		return $result;
	}

	# Single bound.
	my ($key, $val) = $parse_bound->($v);
	if (defined $key) {
		return {
			mode => 'union', count => undef, age_seconds => undef,
			warnings => [], $key => $val,
		};
	}

	Genesis::bail("Invalid lifespan: '%s'", $value);
}

sub _time_unit_to_seconds {
	my ($unit) = @_;
	my $u = lc(substr($unit // '', 0, 1));
	return 86400    if $u eq 'd';
	return 604800   if $u eq 'w';
	return 2592000  if $u eq 'm';
	return 31536000 if $u eq 'y';
	return undef;
}

# template_to_glob_pattern - convert a log path template into a filesystem
# glob pattern suitable for Perl's built-in glob() operator.
#
# Pure function: no IO.  For each {name} in the template, if `name` is a
# key in %concrete the value is substituted directly; otherwise the
# variable is replaced with a shape-matching wildcard from the table:
#
#   {timestamp} -> YYYYMMDDTHHMMSS.mmmZ digit pattern
#   {date}      -> YYYYMMDD digit pattern
#   {time}      -> HHMMSS digit pattern
#   {pid}       -> [0-9]* (variable-length numeric)
#   {env}       -> *
#   {command}   -> *
#
# Tilde-prefixed paths are expanded via Genesis::expand_path before
# variable substitution.
sub template_to_glob_pattern {
	my ($template, %concrete) = @_;

	# Simple tilde expansion only - we need pure string transformation
	# here, not Cwd::abs_path (which resolves symlinks and returns undef
	# for non-existent paths; templates routinely reference subdirs that
	# won't exist until cleanup time).
	my $path = $template;
	$path =~ s{^~/}{$ENV{HOME}/};
	$path =~ s{^~$}{$ENV{HOME}};

	my %wildcards = (
		timestamp => '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9]Z',
		date      => '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]',
		time      => '[0-9][0-9][0-9][0-9][0-9][0-9]',
		pid       => '[0-9]*',
		env       => '*',
		command   => '*',
	);

	# {[sep]name[sep]} grammar - sep is a single char from the set
	# [-_.~/] that wraps the substituted value.  In wildcard mode the
	# sep is preserved literally in the glob pattern, so files matching
	# the explicit-sep form (e.g. "-staging") are matched and files
	# without (env empty case) are not.
	my $sep = qr/[-_.~\/]/;
	$path =~ s{ \{ ($sep)? ([a-z]+) ($sep)? \} }{
		my ($lead, $name, $trail) = ($1 // '', $2, $3 // '');
		if (exists $concrete{$name}) {
			"$lead$concrete{$name}$trail";
		} elsif (exists $wildcards{$name}) {
			"$lead$wildcards{$name}$trail";
		} else {
			"{$lead$name$trail}";
		}
	}gex;

	return $path;
}

# find_log_files - locate log files matching a template, with metadata.
#
# Args:
#   $template - log path template (e.g. '~/.genesis/logs/{env}/{timestamp}.log')
#   %concrete - optional substitutions for specific template variables
#
# Uses Perl's built-in glob() operator (portable across Linux/POSIX/BSD).
#
# Returns: arrayref of hashrefs sorted by mtime descending (newest first):
#   [ { path => '...', mtime => <epoch> }, ... ]
#
# Skips non-files (directories, symlinks to nothing, etc.) and any path
# whose stat() fails.  Empty arrayref when nothing matches.
sub find_log_files {
	my ($template, %concrete) = @_;

	my $pattern = template_to_glob_pattern($template, %concrete);
	my @paths = glob($pattern);

	my @files;
	for my $p (@paths) {
		next unless -f $p;
		my @stat = stat($p);
		next unless @stat;
		push @files, { path => $p, mtime => $stat[9] };
	}

	return [ sort { $b->{mtime} <=> $a->{mtime} } @files ];
}

# apply_retention_policy - decide which files to delete from a list.
#
# Pure function: no IO.  Given a candidate file list (as produced by
# find_log_files) and a parsed retention policy (as produced by
# parse_lifespan), returns the subset of files that should be deleted.
#
# Args:
#   $files  - arrayref of { path, mtime } hashrefs
#   $policy - hashref { mode, count, age_seconds, ... }
#
# Returns: arrayref of file hashrefs (subset of $files)
#
# Semantics by mode:
#   'none'         - keep all (forever); returns empty arrayref
#   'truncate'     - reserved forward-compat; returns empty arrayref
#   'union'        - keep file if EITHER count or age bound votes keep
#   'intersection' - keep file only if BOTH count and age bounds vote keep
#
# A bound that is undef contributes "no opinion" - the result collapses
# to the other bound alone.
sub apply_retention_policy {
	my ($files, $policy) = @_;

	$files //= [];
	return [] if !$policy || $policy->{mode} eq 'none' || $policy->{mode} eq 'truncate';

	my $count       = $policy->{count};
	my $age_seconds = $policy->{age_seconds};
	my $mode        = $policy->{mode};
	my $now         = _now();

	# Both bounds undef in a non-degenerate mode: nothing to decide on,
	# keep everything (parser shouldn't produce this, but be defensive).
	return [] if !defined($count) && !defined($age_seconds);

	my @sorted = sort { $b->{mtime} <=> $a->{mtime} } @$files;

	my @to_delete;
	for my $i (0 .. $#sorted) {
		my $f = $sorted[$i];

		# Each bound votes keep/delete/abstain (undef = abstain)
		my $count_keeps =
			defined($count) ? ($i < $count ? 1 : 0) : undef;
		my $age_keeps =
			defined($age_seconds)
				? (($now - $f->{mtime}) < $age_seconds ? 1 : 0)
				: undef;

		my $keep;
		if ($mode eq 'union') {
			# Kept if any defined bound votes keep
			$keep = 0;
			$keep ||= 1 if defined($count_keeps) && $count_keeps;
			$keep ||= 1 if defined($age_keeps)   && $age_keeps;
		} else {  # intersection
			# Kept only if every defined bound votes keep
			$keep = 1;
			$keep = 0 if defined($count_keeps) && !$count_keeps;
			$keep = 0 if defined($age_keeps)   && !$age_keeps;
		}

		push @to_delete, $f unless $keep;
	}

	# Return oldest-first; operator-friendly for cleanup reporting and
	# matches the natural "files to be deleted, oldest to newest" order.
	return [ sort { $a->{mtime} <=> $b->{mtime} } @to_delete ];
}

# Tiny indirection so tests can stub time(); production code calls
# the real time() via this thunk.
sub _now { time() }

# cleanup_old_logs - find + decide + unlink for a single log config.
#
# Side-effect-ful orchestrator that composes parse_lifespan,
# find_log_files, and apply_retention_policy, then unlinks the
# resulting set.  Tolerant of failures: parser bails and unlink
# errors are recorded in the result, never propagated.
#
# Args:
#   $log_config - hashref with at least `file` and `lifespan` keys
#                 (other keys are ignored)
#
#   %opts:
#     active_path    => path-string  - protect from deletion (current
#                                       session's running log; never
#                                       unlinked even if selected)
#     reserve_slots  => N            - subtract from policy count to
#                                       reserve budget for upcoming
#                                       new files (Subtask F caller
#                                       decides based on on_reuse mode)
#     concrete       => hashref      - per-template-var substitutions
#                                       passed through to find_log_files
#
# Returns: { deleted => [paths], errors => [strings] }
sub cleanup_old_logs {
	my ($log_config, %opts) = @_;

	my $result = { deleted => [], errors => [] };

	return $result unless $log_config
		&& $log_config->{file}
		&& defined($log_config->{lifespan})
		&& length($log_config->{lifespan});

	my $policy;
	my $ok = eval {
		$policy = parse_lifespan($log_config->{lifespan});
		1;
	};
	unless ($ok) {
		my $err = $@;
		$err =~ s/\s+$//;
		push @{$result->{errors}}, "lifespan parse: $err";
		return $result;
	}

	# No-op policies
	return $result if $policy->{mode} eq 'none'
		|| $policy->{mode} eq 'truncate';

	# Reserve slots for an upcoming new file (rotate-archive or
	# templated-new-path) - shrink the effective count budget.
	my $reserve = $opts{reserve_slots} // 0;
	if ($reserve > 0 && defined $policy->{count}) {
		my $adjusted = $policy->{count} - $reserve;
		$adjusted = 0 if $adjusted < 0;
		$policy = { %$policy, count => $adjusted };
	}

	my $concrete = $opts{concrete} // {};
	my $files = find_log_files($log_config->{file}, %$concrete);
	my $to_delete = apply_retention_policy($files, $policy);

	my $active = $opts{active_path};
	for my $f (@$to_delete) {
		if (defined $active && $f->{path} eq $active) {
			next;  # current session's log; protected
		}
		if (_unlink($f->{path})) {
			push @{$result->{deleted}}, $f->{path};
		} else {
			push @{$result->{errors}},
				sprintf("unlink %s: %s", $f->{path}, $!);
		}
	}

	return $result;
}

# Tiny indirection so tests can stub the actual unlink call.
sub _unlink { CORE::unlink($_[0]) }

sub expand_log_template {
	my ($self, $template) = @_;

	# Get timestamp components
	my ($s,$us) = gettimeofday;
	my $ts = sprintf "%s.%03dZ", gmtime($s)->strftime("%Y%m%dT%H%M%S"), $us / 1000;
	my $date = gmtime($s)->strftime("%Y%m%d");
	my $time = gmtime($s)->strftime("%H%M%S");

	my %values = (
		command   => ($ENV{GENESIS_COMMAND} // '') eq '' ? 'unknown' : $ENV{GENESIS_COMMAND},
		timestamp => $ts,
		date      => $date,
		time      => $time,
		pid       => $$,
		env       => $ENV{GENESIS_ENVIRONMENT} // '',
	);

	my $path = $template;

	# Legacy implicit {env}/ slash-removal: when bare {env} appears
	# adjacent to slashes AND env is empty, strip the slash with the
	# var.  Preserved for back-compat but deprecated in favor of the
	# explicit {env/}, {/env} forms below.
	if ($values{env} eq '' && $path =~ /\{env\}/) {
		my $fired = 0;
		$fired += ($path =~ s/\{env\}\///g);
		$fired += ($path =~ s/\/\{env\}\//\//g);
		$fired += ($path =~ s/\/\{env\}$//g);
		if ($fired) {
			require Genesis;
			Genesis::warning(
				"Template '%s' uses implicit {env}/ slash-removal which ".
				"is deprecated; use {env/}, {/env}, or {-env-} for ".
				"explicit separator handling.",
				$template
			);
		}
	}

	# {[sep]name[sep]} grammar - sep is a single char from [-_.~/].
	# Empty values drop both the value and its separators.
	my $sep = qr/[-_.~\/]/;
	$path =~ s{ \{ ($sep)? ([a-z]+) ($sep)? \} }{
		my ($lead, $name, $trail) = ($1 // '', $2, $3 // '');
		if (exists $values{$name}) {
			my $v = $values{$name};
			(defined($v) && length($v)) ? "$lead$v$trail" : '';
		} else {
			"{$lead$name$trail}";
		}
	}gex;

	# Clean up any double slashes
	$path =~ s/\/\/+/\//g;

	return $path;
}

sub is_logging {
	my ($self,$level,$log) = @_;
	$log ||= '<terminal>';
	return meets_level($self->{logs}{$log}{level}, $level)
		if ($self->{logs}{$log} && defined($self->{logs}{$log}{level}));
	return 0;
}

sub style {
	my ($self,$log) = @_;
	$log ||= '<terminal>';
	die "invalid log: $log\n" unless defined($self->{logs}{$log});
	return $self->{logs}{$log}{style};
}

sub set_level {
	my ($self,$level,$log) = @_;
	$log ||= '<terminal>';
	die "invalid log: $log\n" unless defined($self->{logs}{$log});
	$level = find_log_level($level);
	@{$self->{logs}{$log}}{qw/level_ord level/} = (level_ord($level),$level);
	return $self;
}

sub log_styles {
	return {
		output    => {colors => "Ck", pri => 6, emoji => 'printer'},
		info      => {colors => "cW", pri => 6, emoji => 'information'},
		debug     => {colors => "mW", emoji => 'crystal-ball'},
		warning   => {colors => "ky", pri => 4, emoji => 'warning'},
		notice    => {colors => "bw", pri => 4, emoji => 'megaphone'},
		error     => {colors => "RW", pri => 3, emoji => 'collision'},
		fatal     => {colors => "rY", pri => 0, emoji => 'stop-sign'},
		trace     => {colors => "GW", emoji => 'detective', show_stack => 'current'},
		qtrace    => {colors => "gW", emoji => 'detective'},
		dumpvar   => {colors => "BW", show_scope => 'current', emoji => 'magnifying-glass', raw => 1},
		dumpstack => {colors => "Yk", emoji => 'pancakes', raw => 1},
	}->{$_[0]}
}

sub output  { shift->_log("OUTPUT",  log_styles('output'),  @_) }
sub info    { shift->_log("INFO",    log_styles('info'),    @_) }
sub debug   { shift->_log("DEBUG",   log_styles('debug'),   @_) }
sub notice  { shift->_log("NOTICE",  log_styles('notice'),  @_) }
sub warning { shift->_log("WARNING", log_styles('warning'), @_) }
sub error   { shift->_log("ERROR",   log_styles('error'),   @_) }
sub fatal   { shift->_log("FATAL",   log_styles('fatal'),   @_) }
sub trace   { shift->_log("TRACE",   log_styles('trace'),   @_); }
sub qtrace  { shift->_log("TRACE",   log_styles('qtrace'),  @_); }

sub dump_var {
	my $self = shift;
	my $options = {};
	my @args = @_;
	while (ref($_[0]) eq 'HASH') {
		my $more_options = shift @_;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	# TODO: Too many ways to indicate offset - old version must be fixed in
	# caller context
	my $scope = delete($options->{offset}) || 0;
	$scope += abs(shift) if (defined $_[0] && $_[0] =~ '^-?\d+$');

	require Data::Dumper;
	local $Data::Dumper::Indent  = 1; # 2-space indent
	local $Data::Dumper::Deparse = 1;
	local $Data::Dumper::Terse   = 1;
	my (%vars) = @_;
	for (keys %vars) {
		chomp (my $value = Data::Dumper::Dumper($vars{$_}));
		$self->_log("VALUE", {%{log_styles('dumpvar')}, offset => $scope}, $options, "#M{%s} = %s", $_, $value);
	}
}

sub dump_stack {
	my $self = shift;
	my $options = {};
	while (ref($_[0]) eq 'HASH') {
		my $more_options = shift @_;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	# TODO: Too many ways to indicate offset - old version must be fixed in
	# caller context
	my $scope = $options->{offset} || 0;
	$scope += abs(shift) if (defined $_[0] && $_[0] =~ '^-?\d+$');

	my @stack = get_stack($scope+1);
	my %sizes = (sub => 10, line => 4, file => 4);
	for my $type (keys %sizes) {
		$sizes{$type} = (sort {$b<=>$a} ($sizes{$type}, map {length($_->{$type}||'')} @stack))[0];
	}

	print STDERR "\n"; # Ensures that the header lines up at the cost of a blank line
	my $header = csprintf("#Wku{%*s}  #Wku{%-*s}  #Wku{%-*s}\n", $sizes{line}, "Line", $sizes{sub}, "Subroutine", $sizes{file}, "File");
	$self->_log("STACK", { %$options, %{log_styles('dumpstack')} }, $header.join("\n",map {
		csprintf("#w{%*s}  #Y{%-*s}  #Ki{%s}", $sizes{line}, $_->{line}, $sizes{sub}, $_->{sub}||'', $_->{file})
	} @stack));
}

sub _log {
	my ($self, $level, @contents) = @_;
	my $options = {};
	while (ref($contents[0]) eq 'HASH') {
		my $more_options = shift @contents;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	unshift @contents, "%s" if scalar(@contents) == 1;
	$level = $options->{level}//$level;
	my $label =  $options->{label} || $level;
	$level =~ s/ +$//g;

	my ($s,$us) = gettimeofday;
	my $ts = sprintf "%s.%03dZ", gmtime($s)->strftime("%Y-%m-%dT%H:%M:%S"), $us / 1000;

	my @stack = ($level eq 'STACK' || ! meets_level($level, $self->{capture_stack_min_level})) ? () :
		get_stack(($options->{offset}||0)+2);

	push @{$self->{buffer}}, {
		level      => $level,
		label      => $label,
		colors     => $options->{colors} // '--',
		emoji      => $options->{emoji}  // '',
		priority   => $options->{pri}    // 7,
		timestamp  => $ts,
		contents   => \@contents,
		pending    => $options->{pending},
		reset      => $options->{reset},
		show_stack => $options->{show_stack},
		stack      => \@stack,
		raw        => $options->{raw},

		# Terminal specific options
		prefix     => $options->{prefix},
		style      => $options->{style},
	};

	# Check if there are any logs for the given level
	$self->flush_logs();
	return;
}

my $flushing=0;
sub flush_logs {
	my $self = shift;
	my $last_line = $#{$self->{buffer}};

	return if $flushing; $flushing = 1;

	my ($s,$us) = gettimeofday;
	my $ms = $s * 1000 + int($us/1000);

	# Process templates first
	for my $template (keys %{$self->{log_templates}}) {
		next if $self->{realized_logs}{$template}; # Already realized

		# Check if we should skip logging for this command
		my $skip_commands = $self->{log_templates}{$template}{skip_commands} || [];
		if ($ENV{GENESIS_COMMAND} && grep { $_ eq $ENV{GENESIS_COMMAND} } @$skip_commands) {
			# Mark as realized but don't create log
			$self->{realized_logs}{$template} = '<skipped>';
			next;
		}

		my $actual_log = $self->expand_log_template($template);
		my $options = $self->{log_templates}{$template}{options};

		# Configure the actual log file
		$self->configure_log($actual_log, %$options);
		$self->{realized_logs}{$template} = $actual_log;
	}

	# Process realized logs from templates (no need to do anything here, they're already configured)

	for my $log (keys %{$self->{logs}}) {
		my $config = $self->{logs}{$log};
		for my $line_number ($config->{next_entry}..$last_line) {
			my (
					$level, $ts,      $label, $colors, $emoji, $priority, $contents, $show_stack, $stack, $pending, $reset, $raw, $term_prefix, $term_style
			)	= @{@{$self->{buffer}}[$line_number]}{
				qw/level   timestamp label   colors   emoji   priority   contents   show_stack   stack   pending   reset   raw   prefix        style/
			};

			next unless meets_level($config->{level},$level);

			$reset = 1 if defined($config->{last_label}) && $config->{last_label} ne $label;

			unshift(@$contents, '' ) unless scalar(@$contents);
			unshift(@$contents, "%s") if scalar(@$contents) == 1;
			my ($template, @values) = @$contents;

			do {
				local $ENV = $ENV;
				$ENV{NOCOLOR} = $config->{no_color} if defined($config->{no_color});
				$ENV{GENESIS_NO_UTF8} = $config->{no_utf8} if defined($config->{no_utf8});
				my $columns = $log eq '<terminal>' ? terminal_width : ($config->{width} || 120);
				my ($prefix,$indent);

				my $style = $config->{style} || 'pointer';
				$style = $term_style if defined($term_style) && $log eq '<terminal>';

				if ($log eq '<terminal>' && grep {$_ eq $level} (qw(OUTPUT INFO))) {
					$prefix = '';
					$colors = '';
				} elsif ($style eq 'fun') {
					$prefix = sprintf("#%s{[#E{%s}%s]} ",$colors,$emoji,$label);
					$prefix = "#K{$ts} $prefix" if $config->{timestamp};
				} elsif ($style eq 'plain') {
					$prefix = "#${colors}{[$label]} ";
					$prefix = "#K{$ts} $prefix" if $config->{timestamp};
				} elsif ($style eq 'rfc-5424') {
					$priority += 8; # See https://datatracker.ietf.org/doc/html/rfc5424#section-6.2.1
					my $msgid = '-'; #FIXME: Not yet implemented
					no warnings 'once';
					my $cmd = $Genesis::Commands::COMMAND//'-';
					$prefix = sprintf(
						"<%s>1 %s %s genesis %s %s [%s v=\"%s\" c=\"%s\"] ",
						$priority, $ts, $self->{hostname}, $self->{pid}, $msgid,
						$label,
						#$self->{user},
						$self->{version}, $cmd,
						#$ENV{GENESIS_ORIGINATING_DIR}//'-',
						#$ENV{GENESIS_ROOT}//'-'
					);
					# RFC-5424 cannot wrap lines
					$pending = undef;
					$columns = 999;
					$indent = "  ";
				} else { # current default - if ($style eq 'pointer') {
					$prefix = $label;
					my ($gt,$gtc);
					if (envset 'NOCOLOR' || envset 'GENESIS_NO_UTF8') {
						$colors = $gtc = substr($colors,0,1) || '-';
						$gt = '>';
						$gtc = '-';
					} else {
						$gt = csprintf('#@{>}');
						$gtc = substr($colors,1,1)||'-';
						$prefix = " $prefix ";
					}
					$prefix = "$ts $prefix" if $config->{timestamp};
					$prefix = sprintf("#%s{%s}#%s{%s} ", $colors,$prefix,$gtc,$gt)
				}
				$prefix = $term_prefix.$prefix if defined($term_prefix) && $log eq '<terminal>';

				$indent ||=  ' ' x csize($prefix);

				my $content;
				eval {
					our @trap_warnings = qw/uninitialized/;
					push @trap_warnings, qw/missing redundant/ if $^V ge v5.21.0;
					use warnings FATAL => @trap_warnings;
					$content = sprintf($template, @values);
				};
				if ($@) {
					require Data::Dumper;
					$content = "ERROR: $@\n".Data::Dumper::Dumper({template => $template, values => \@values});
					$show_stack = 'full';
					#TODO: log error without trigging another error in the log system...
				}
				my ($pre_pad, $post_pad) = ("","");
				($pre_pad, $content)  = $content =~ m/\A([\r\n]*)(.*)\z/s;
				($content, $post_pad) = $content =~ m/\A(.*?)([\r\n]*)\z/s unless $pending;

				# Swallow up pure whitespace if not on terminal
				my $last_waiting = $config->{waiting};
				$config->{waiting} = 0;
				next if ($log ne '<terminal>' && (!$last_waiting || $reset) && decolorize($content) =~ /\A\s*\z/);

				my $start_column = $last_waiting && !$reset ? $last_waiting : 0;
				my $out = wrap($content, $raw ? -1 : $columns, $colors ? $prefix : $indent, length($indent), undef, $start_column);

				# TODO: rfc-5424 may need to have newlines converted into \n strings.
				$reset = $reset && $last_waiting ? "\n" : '';
				if ($pending) {
					$config->{waiting} = (sort {$b <=> $a} (length($indent), length((split("\n",$out,-1))[-1])))[0];
				}

				# TODO: Support for logging STDOUT to all logs, not just STDOUT
				my $fh;
				if ($log eq '<terminal>') {
					$fh = ($level eq "OUTPUT") ? *STDOUT : *STDERR;
					if ($reset && $config->{waiting_fh}) {
						my $waiting_fh = $config->{waiting_fh};
						print $waiting_fh $reset;
					}
					$reset = '';
					$config->{waiting_fh} = $pending ? $fh : undef;
				} else {
					my $file = $log;
					$file =~ s/^~/$ENV{HOME}/;
					open $fh, '>>:encoding(UTF-8)', $file
						or die "Could not open $log for writing logs: $!\n";

					# Write command line as first entry if this is a new file
					if ($ENV{GENESIS_FULL_CALL} && !$self->{command_logged}{$log} && -z $file) {
						print $fh "Command: $ENV{GENESIS_FULL_CALL}\n\n";
						$self->{command_logged}{$log} = 1;
					}
				}
				$pre_pad =~ s/\A[\r\n]+// unless ($log eq '<terminal>' || ($last_waiting && !$reset));
				$post_pad =~ s/[\r\n]+\z// unless ($log eq '<terminal>' || $pending);
				$out .= "\n" unless $pending;
				print $fh csprintf("%s", $reset.$pre_pad.$out.$post_pad);
				$config->{last_label} = $label;

				# Deal with stack
				$show_stack = $config->{show_stack} if ($show_stack//"default") eq "default";
				$show_stack = ($pending || $show_stack eq 'none')
					? 'none'
					: (($show_stack||'') eq 'full' || ($config->{show_stack}||'') eq 'full')
					? 'full'
					: ((($show_stack||'') eq 'fatal' || ($config->{show_stack}||'') eq 'fatal') && $level eq 'FATAL')
					? 'full'
					: (($show_stack||'') eq 'current' || ($config->{show_stack}||'') eq 'current')
					? 'current'
					: 'invalid' ;

				unless ( $show_stack eq 'none' || $show_stack eq 'invalid') {
					for (@$stack) {
						my $line = sprintf("#Ki{ %s:L%d%s}", $_->{file}, $_->{line}, $_->{sub} ? " (in $_->{sub})" : " (pid: $$)");
						$out = wrap($line, $columns, $indent."#K\@{^-}");
						print $fh csprintf("%s\n", $out);
						last if $show_stack eq 'current';
					}
					print $fh "\n" if $log eq '<terminal>';
				}
				close $fh unless $log eq '<terminal>';
			}
		}
		$config->{next_entry} = $last_line+1;
	}
	$flushing = 0;
}

sub replay{
	my ($self,$level,$log) = @_;
	$log //= '<terminal>';

	my $original_level = $self->{logs}{$log}{level};
	$self->set_level($level) if $level;
	$self->{logs}{$log}{next_entry}=0;
	$self->flush_logs();
	$self->set_level($original_level) if $level;
	return
}

## Package functions

sub _log_item_level_map {
	return {
		'NONE'    => 0,
		'OUTPUT'  => 1,
		'FATAL'   => 2,
		'ERROR'   => 2,
		'WARNING' => 3,
		'NOTICE'  => 3,
		'INFO'    => 4,
		'DEBUG'   => 5,
		'VALUE'   => 6,
		'TRACE'   => 6,
		'STACK'   => 6,
	}
};

sub level_ord {
	return _log_item_level_map->{uc($_[0])}
}

sub log_levels {
	return (
		'NONE',
		'OUTPUT',
		'ERROR',
		'WARNING',
		'INFO',
		'DEBUG',
		'TRACE',
	);
};


# TODO: Replace this with a better call by those that call it.
sub get_scope {
	my ($scope) = @_;
	my $out = "";
	for (get_stack($scope+1)) {
		$out .= csprintf("#K\@{^-}#Ki{ %s:L%d%s\n}", $_->{file}, $_->{line}, $_->{sub} ? " (in $_->{sub})" : '');
		last unless envset ("GENESIS_STACK_TRACE");
	}
	chomp $out;
	return $out;
}

sub get_stack {
	my ($scope) = @_;
	require Genesis; # FIXME: humanize_path should be moved to Genesis::IO or Genesis::Files

	my ($file,$line,$sub,@stack,@info);
	while (@info = caller($scope++)) {
		$sub = $info[3];
		push @stack, {line => $line, sub => $sub, file => Genesis::humanize_path($file)} if ($file);
		(undef, $file, $line) = @info;
	}
	push @stack, {line => $line, file => Genesis::humanize_path($file)};
	return @stack;
}

# This should only be used to validate user input, not internal
sub find_log_level {
	my $log_level = shift;

	$log_level = uc($log_level);
	unless (level_ord($log_level)) {
		my @log_levels = grep {$_ =~ qr/^$log_level.*/i} (log_levels());
		if (scalar(@log_levels) == 1) {
			$log_level = $log_levels[0];
		} elsif (scalar(@log_levels) > 1) {
			require Genesis;
			Genesis::bail(
				"Ambiguous log level $log_level: please specify one of ".join(", ",@log_levels)
			);
		} else {
			require Genesis;
			Genesis::bail(
				"Not a valid log level '$log_level': please specify one of ".join(", ",log_levels())
			);
		}
	}
	return $log_level;
}

sub meets_level {
	my ($level, $target) = @_;
	$level = level_ord($level) unless grep {$level eq $_} (values %{_log_item_level_map()});
	$target = level_ord($target) unless grep {$target eq $_} (values %{_log_item_level_map()});
	return $level >= $target;
}

1;
