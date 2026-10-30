package Genesis::Env::PendingChanges;
use strict;
use warnings;
use utf8;

use Genesis;
use Genesis::Term qw/terminal_width/;
use Genesis::CI::Marker ();
use JSON::PP ();
use POSIX ();
use Time::Seconds ();

# What deploying an environment's branch would change, read-only (D123).
# See PendingChanges.pod.

my $MASK       = '<redacted>';
my $MASK_DIFF  = '<redacted: changed>';
my $EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
my $RULE_WIDTH = 80;
my $RUN        = 3;

### Class Methods {{{

# new - a report for one loaded environment {{{
sub new {
	my ($class, $env, %opts) = @_;
	return bless {
		env          => $env,
		redact       => $opts{redact}  ? 1 : 0,
		verbose      => $opts{verbose} ? 1 : 0,
		summary_file => $opts{summary_file},
		pending      => 0,
		facts        => {configs => 0, uploads => 0},
		lines        => {},
	}, $class;
}

# }}}
# }}}

### Instance Methods {{{

# report - read everything, then print the report, and answer whether anything is pending {{{
sub report {
	my ($self) = @_;
	my $env = $self->{env};

	# Read before anything is printed: rendering the manifest and reaching
	# the director print their own progress, which then stands above the
	# report rather than inside it.
	my $git = $self->_read_commits;
	# The secrets first: what is missing is named in the render (D129).
	$self->_section(secrets  => sub {$self->_secrets});
	$self->_section(manifest => sub {$self->_manifest});
	$self->_section(configs  => sub {$self->_configs});
	$self->_section(uploads  => sub {$self->_uploads});

	my @summary = $self->_summary($git);
	$self->_write_summary(@summary) if defined $self->{summary_file};

	_frame(sprintf('Summary: %s (%s)', $env->name, $env->type));
	info("\n[[  >>%s", $_) for @summary;
	_frame();

	$self->_print_files($git);
	$self->_print_commits($git);
	_rule('What the deploy would change on the director');
	for (['Secrets', 'secrets'], ['Manifest', 'manifest'], ['BOSH configs', 'configs'], ['Uploads', 'uploads']) {
		_heading($_->[0]);
		info(@$_) for @{$self->{lines}{$_->[1]}};
	}

	my ($verdict, $colour) = $self->_verdict;
	_frame($verdict, $colour);
	return $self->{pending};
}

# }}}
# blocked - whether the deploy needs a secret only an operator can provide {{{
sub blocked {
	return scalar @{(($_[0]->{fixes} || {})->{provide}) || []};
}

# }}}
# }}}

### The git half {{{

# _read_commits - the range since the deployed commit, or the seed, and its commits {{{
sub _read_commits {
	my ($self) = @_;
	my $env = $self->{env};
	my $git = $env->top->git;
	my $record = $self->_record;
	my $deployed = $record ? $record->lookup('git.commit') : undef;

	my %c = (branch => $env->top->branch_for($env->name), deployed => $deployed);
	if ($deployed && $git->is_ancestor($deployed, 'HEAD')) {
		@c{qw/base since/} = ($deployed, 'the last deploy');
	} else {
		$c{off_branch} = $deployed;
		my ($root) = reverse grep {/\S/} split /\n/,
			scalar(run({dir => $git->root, stderr => 0}, 'git', 'rev-list', '--max-parents=0', 'HEAD')) // '';
		my $seed = $root && _message($git, $root);
		if ($seed && Genesis::CI::Marker::is_seed($seed)) {
			@c{qw/base since/} = ($root, 'the branch was cut');
		} else {
			$c{since} = 'the branch began';
		}
	}

	my @scope = $git->prefix ? ($git->prefix) : ();
	my $range = $c{base} ? "$c{base}..HEAD" : 'HEAD';
	$c{commits} = [map {_entry($git, $_, \@scope)} reverse $git->log_subjects($range, body => 1)];
	$c{stat}    = [_stat($git, $c{base})];
	$self->{pending}++ if @{$c{commits}};
	return \%c;
}

# }}}
# _entry - one commit, as the report reads it {{{
sub _entry {
	my ($git, $commit, $scope) = @_;
	my ($subject) = split /\n/, $commit->{message};
	my %e = (sha => $commit->{sha}, files => [$git->unprefixed($git->commit_files($commit->{sha}, @$scope))]);
	my $own = _meta($git, $commit->{sha}) // {};
	my ($control) = Genesis::CI::Marker::in_text($commit->{message});
	if (defined $control) {
		my $meta = _meta($git, $control);
		%e = (%e, kind => 'propagated', control => $control, %{$meta // {%$own, subject => $subject, unread => 1}});
		$e{squash} = $1 if $commit->{message} =~ /Squashes (\d+) control commits/;
	} else {
		%e = (%e, kind => Genesis::CI::Marker::is_seed($commit->{message}) ? 'seed' : 'manual', %$own, subject => $subject);
	}
	return \%e;
}

# }}}
# _print_files - the range as a diff stat under the deployment root {{{
sub _print_files {
	my ($self, $c) = @_;
	_heading("Files changed since $c->{since}");
	return info("[[  >>#G{none}") unless @{$c->{stat}};
	info("[[  >>%s", $_) for @{$c->{stat}};
}

# }}}
# _print_commits - the range's commits, oldest first, like runs folded {{{
sub _print_commits {
	my ($self, $c) = @_;
	_heading('Commits, oldest first');
	my @commits = @{$c->{commits}};
	return info("[[  >>#G{none}") unless @commits;

	# One width for every date, so each label starts in one column and a
	# wrapped first line hangs under it.
	$_->{when} = defined $_->{epoch} ? sprintf('%s  (%s)', _stamp($_->{epoch}), _ago($_->{epoch})) : ''
		for @commits;
	($self->{when_width}) = sort {$b <=> $a} map {length $_->{when}} @commits;

	my @groups;
	for my $e (@commits) {
		my $key = join("\0", $e->{kind}, $e->{author} // '', _norm($e->{subject}));
		if (@groups && $groups[-1]{key} eq $key) {push @{$groups[-1]{run}}, $e}
		else {push @groups, {key => $key, run => [$e]}}
	}
	for my $g (@groups) {
		my @run = @{$g->{run}};
		if ($self->{verbose} || @run < $RUN) {
			$self->_print_commit($_) for @run;
			next;
		}
		$self->_print_commit($run[0]);
		my @mid = @run[1 .. $#run-1];
		info("[[  >>... %d more \"%s\" commits, %s to %s ...", scalar(@mid), _norm($run[0]{subject}),
			_stamp($mid[0]{epoch}), _stamp($mid[-1]{epoch}));
		$self->_print_commit($run[-1]);
	}
}

# }}}
# _print_commit - one commit's two lines, and its files under --verbose {{{
sub _print_commit {
	my ($self, $e) = @_;
	my $what = $e->{kind} eq 'propagated'
		? sprintf('#G{propagated} from control@%s', substr($e->{control}, 0, 8))
		: sprintf('#Y{manual} commit %s', substr($e->{sha}, 0, 8));
	my $count = scalar @{$e->{files}};
	info("[[  %-*s  >>%s by %s%s", $self->{when_width} // 0, $e->{when} // '', $what, $e->{author} // 'unknown',
		$e->{squash} ? " (squash of $e->{squash} control commits)" : '');
	info("[[                >>\"%s\"  #K{(%d file%s)}", $e->{subject} // '', $count, $count == 1 ? '' : 's');
	return unless $self->{verbose};
	info("[[                  >>%s", $_) for @{$e->{files}};
}

# }}}
# }}}

### The director half {{{

# _secrets - what the deploy's -F would do to the secrets, and what it cannot {{{
#
# The render that follows reads each missing secret as the placeholder named
# here, so it shows the manifest whole without a value the vault lacks.
sub _secrets {
	my ($self) = @_;
	my $f = $self->{fixes} = $self->{env}->secret_fixes;
	my %placeholder;
	for ([generate => '<generated on deploy>'], [provide => '<must be provided>']) {
		my ($kind, $text) = @$_;
		$placeholder{'/'.($_->{full_path} =~ s{^/}{}r)} = $text for grep {$_->{why} eq 'missing'} @{$f->{$kind}};
	}
	$self->_provider->{secret_placeholders} = \%placeholder;

	my $said = 0;
	for my $e (@{$f->{generate}}) {
		$said++; $self->{pending}++;
		$self->_say("[[  - >>the deploy would generate #C{%s} (missing)", $e->{path});
	}
	for my $e (@{$f->{rotate}}) {
		$said++; $self->{pending}++;
		$self->_say("[[  - >>the deploy would rotate #C{%s} (invalid)", $e->{path});
	}
	for my $e (@{$f->{provide}}) {
		$said++; $self->{pending}++;
		$self->_say("[[  - >>#R{must be provided} #C{%s} (%s): %s", $e->{path}, $e->{why}, $e->{prompt} // '');
	}
	$self->_say("[[  >>#G{none}") unless $said;
}

# }}}

# _manifest - the branch's manifest against the director's and exodus's {{{
sub _manifest {
	my ($self) = @_;
	my $env = $self->{env};

	my $provider = $self->_provider;
	my $current  = $self->_current;
	my @secrets  = _redacted_paths(eval {$provider->redacted(subset => 'pruned')->data});

	my $record   = $self->_record;
	my $exodus   = _yaml_artifact($record, 'manifest');
	my $director = $env->use_create_env ? undef : $self->_director_manifest;

	# A first deploy: nothing anywhere to compare with, so the whole manifest
	# is the change, shown as additions against an empty one.
	unless ($director || $exodus) {
		$self->{facts}{first} = 1;
		$self->_compare('nothing deployed, a first deploy', {}, $current, \@secrets,
			'nothing', 'branch', '');
	} else {
		if ($env->use_create_env) {
			$self->_say("[[  >>a create-env environment has no director; comparing with the last deploy alone.");
		} else {
			$self->_compare('the director\'s live manifest', $director, $current, \@secrets,
				'director', 'branch', 'the director holds no manifest for '.$env->deployment_name);
		}
		$self->_compare('the last manifest Genesis deployed (exodus)', $exodus, $current, \@secrets,
			'exodus', 'branch', 'no deployed manifest is recorded in exodus');

		if ($director && $exodus) {
			my ($diff) = $self->_diff($exodus, $director, \@secrets, 'exodus', 'director');
			if ($diff) {
				$self->{facts}{drift} = 1;
				$self->_say("[[  >>#R{drift:} the director's manifest differs from the last one Genesis ".
					"deployed, so something was deployed outside Genesis:\n\n%s", $diff);
			}
		}

		my $vars = eval {$provider->deployment(subset => 'bosh_vars')->data};
		if ($vars && %$vars) {
			my @var_secrets = _redacted_paths(eval {$provider->redacted(subset => 'bosh_vars')->data});
			$self->_compare('the last deployed BOSH variables', _yaml_artifact($record, 'vars'),
				$vars, \@var_secrets, 'exodus', 'branch', 'no deployed BOSH variables are recorded');
		}
	}

	my $r = $provider->entombment_results;
	if ($r && $r->{total}) {
		$self->_say("[[  >>secrets: %d referenced, %s", $r->{total},
			($r->{exists} // 0) == $r->{total} ? 'all already entombed in CredHub'
			: sprintf('%d already entombed in CredHub, %d new, %d altered',
				map {$r->{$_} // 0} qw/exists new altered/));
	} elsif (@secrets) {
		$self->_say("[[  >>secrets: %d vault values referenced%s", scalar(@secrets),
			$self->{redact} ? ', shown only as changed or unchanged' : '');
	}
}

# }}}
# _configs - configs the deploy would upload, and those moved on the director {{{
sub _configs {
	my ($self) = @_;
	my $env = $self->{env};
	return $self->_say("[[  >>a create-env environment uses no director configs.") if $env->use_create_env;

	my $bosh = $env->with_bosh->bosh;
	require Genesis::Commands::Bosh;
	my ($configs, $notes) = Genesis::Commands::Bosh::_bosh_configs_provided($env, $bosh);
	my $said = 0;
	for my $config (@$configs) {
		my $status = Genesis::Commands::Bosh::_bosh_configs_status($config);
		next if $status eq 'identical';
		$self->{pending}++; $said++; $self->{facts}{configs}++;
		my $diff = $status eq 'missing' ? '' : $self->_config_diff(
			{content => $config->{uploaded}, label => 'uploaded'},
			{content => $config->{content},  label => 'synthesized'}, $config->{diff});
		$self->_say("[[  - >>%s config %s would be uploaded (%s on the director)%s",
			$config->{type}, $config->{name}, $status eq 'missing' ? 'missing' : 'different',
			$diff ? ":\n\n$diff" : '');
	}

	my $ran    = _json($bosh, '/deployment_configs?deployment='.$env->deployment_name) || [];
	my $latest = _json($bosh, '/configs?latest=true') || [];
	my %ran    = map {my $c = $_->{config} || {}; ("$c->{type}/$c->{name}" => $c->{id})} @$ran;
	for my $config (sort {"$a->{type}/$a->{name}" cmp "$b->{type}/$b->{name}"}
	                grep {$_->{type} =~ /^(cloud|runtime)$/} @$latest) {
		my $key = "$config->{type}/$config->{name}";
		if (!exists $ran{$key}) {
			next unless @$ran;
			$self->{pending}++; $said++; $self->{facts}{configs}++;
			my $content = $config->{content} // '';
			$content = $self->_config_diff({content => '', label => 'none'},
				{content => $content, label => "id $config->{id}"}) if $self->{redact};
			$self->_say("[[  - >>%s config %s is new on the director since the last deploy:\n\n%s",
				$config->{type}, $config->{name}, $content);
		} elsif ($ran{$key} ne $config->{id}) {
			my $old = (_json($bosh, "/configs/$ran{$key}") || {})->{content} // '';
			my $diff = $self->_config_diff({content => $old, label => "id $ran{$key}"},
				{content => $config->{content} // '', label => "id $config->{id}"});
			$self->{pending}++; $said++; $self->{facts}{configs}++;
			$self->_say("[[  - >>%s config %s changed on the director since the last deploy:\n\n%s",
				$config->{type}, $config->{name}, $diff);
		}
	}
	$self->_say("[[  >>#G{none}") unless $said;
}

# }}}
# _uploads - releases and stemcells the director lacks {{{
sub _uploads {
	my ($self) = @_;
	my $env = $self->{env};
	return $self->_say("[[  >>a create-env environment uploads nothing to a director.") if $env->use_create_env;

	my $manifest = $self->_current;
	my $bosh     = $env->with_bosh->bosh;
	my %releases = map {("$_->{name}/$_->{version}" => 1, "$_->{name}/" => 1)} $bosh->releases;
	my %os       = map {($_->{os} => 1, "$_->{os}/$_->{version}" => 1)} values %{$bosh->stemcells};

	my @missing;
	for my $r (@{$manifest->{releases} || []}) {
		my $want = ($r->{version} // '') eq 'latest' ? "$r->{name}/" : "$r->{name}/$r->{version}";
		push @missing, "release $r->{name}/$r->{version}" unless $releases{$want};
	}
	for my $s (@{$manifest->{stemcells} || []}) {
		my $os = $s->{os} // $s->{name} // '';
		my $want = ($s->{version} // '') eq 'latest' ? $os : "$os/$s->{version}";
		push @missing, "stemcell $os/$s->{version}" unless $os{$want};
	}
	return $self->_say("[[  >>#G{none}") unless @missing;
	$self->{pending}++;
	$self->{facts}{uploads} = scalar @missing;
	$self->_say("[[  - >>the deploy would upload %s", $_) for @missing;
}

# }}}
# }}}

### The summary {{{

# _summary - the summary's paragraphs, plain text {{{
sub _summary {
	my ($self, $c) = @_;
	my $env = $self->{env};
	my $f   = $self->{facts};
	my @commits = grep {$_->{kind} ne 'seed'} @{$c->{commits}};
	my @p;

	if (@commits) {
		my ($first, $last) = ($commits[0]{epoch}, $commits[-1]{epoch});
		my $files = _stat_files($c->{stat});
		my $span = (defined $first && defined $last && $last - $first >= 86400)
			? sprintf(', %s to %s (%s)', _day($first), _day($last),
				strfuzzytime(Time::Seconds->new($last - $first)))
			: defined $last ? sprintf(', %s', _day($last)) : '';
		push @p, sprintf('%d commit%s pending%s, changing %d file%s.',
			scalar(@commits), @commits == 1 ? '' : 's', $span, $files, $files == 1 ? '' : 's');
	} else {
		push @p, 'No commits are pending: the branch is at the deployed commit.';
	}

	my $record = $self->_record;
	my $when = $record ? sprintf('%s, by %s', strfuzzytime($record->completed),
		$record->lookup('user.shell') // 'unknown') : undef;
	if (!$record) {
		push @p, sprintf('%s has never been deployed.', $env->name);
	} elsif ($c->{off_branch} || !$c->{deployed}) {
		push @p, sprintf('It has never deployed from %s: its last deploy (%s) ran from '.
			'another branch, before the pipeline.', $c->{branch}, $when);
	} else {
		push @p, sprintf('Last deployed %s, at %s.', $when, substr($c->{deployed}, 0, 8));
	}

	my $changes = $self->_changes;
	if ($f->{first}) {
		my $m = $self->_current;
		my @ig = @{$m->{instance_groups} || []};
		my $vms = 0; $vms += ($_->{instances} // 0) for @ig;
		push @p, sprintf('Deploying it creates deployment %s%s.', $env->deployment_name, join('', map {", $_"}
			(@ig ? sprintf('with %d instance group%s (%d VM%s)', scalar(@ig), @ig == 1 ? '' : 's', $vms, $vms == 1 ? '' : 's') : ()),
			_count(scalar(@{$m->{releases} || []}), 'release'),
			(map {"stemcell ".($_->{os} // $_->{name} // '?')."/".($_->{version} // '?')} @{$m->{stemcells} || []})));
	} elsif ($changes) {
		push @p, "Deploying it $changes.";
	} elsif (@commits) {
		push @p, 'Deploying it changes nothing on the director: the manifest matches what is '.
			'deployed, and no configs or uploads are due.  '.(($c->{off_branch} || !$c->{deployed})
				? "The deploy records this branch's commit, after which redeploys work."
				: 'The deploy only records the newer commit.');
	} else {
		push @p, 'The director matches the deployed commit; nothing is pending.';
	}
	# A first deploy's sentence names what it creates; what it does to the
	# secrets on the way is said beside it.
	if ($f->{first} && (my $secrets = join(', and ', grep {/secret/} split /, and /, $changes))) {
		push @p, "The deploy also $secrets.";
	}
	push @p, "The director's manifest differs from the last one Genesis deployed, so ".
		'something was deployed outside Genesis.' if $f->{drift};
	if (my $n = $self->blocked) {
		push @p, sprintf('Deploying it is blocked: %s must be set first.',
			_count($n, 'user-provided secret'));
	}
	return @p;
}

# }}}
# _changes - what the deploy would change on the director, as a phrase, or '' {{{
sub _changes {
	my ($self) = @_;
	my $f = $self->{facts};
	my @what = (($f->{manifest} ? ('the manifest') : ()), _count($f->{configs}, 'BOSH config'));
	my $s = $self->{fixes} || {};
	my @parts = ((@what ? ('changes '.join(' and ', @what)) : ()),
		($f->{uploads} ? ('uploads '._count($f->{uploads}, 'release or stemcell', 'releases or stemcells')) : ()),
		(@{$s->{generate} || []} ? ('generates '._count(scalar(@{$s->{generate}}), 'missing secret')) : ()),
		(@{$s->{rotate}   || []} ? ('rotates '._count(scalar(@{$s->{rotate}}), 'invalid secret')) : ()));
	return join(', and ', @parts);
}

# }}}
# _verdict - the closing line and its colour {{{
sub _verdict {
	my ($self) = @_;
	my $name = $self->{env}->name;
	my $f = $self->{facts};
	my ($line, $colour) =
		  $self->blocked    ? ("Deploying $name is blocked", 'R')
		: $f->{first}       ? ("A first deploy is pending for $name", 'Y')
		: $self->_changes   ? ("Changes are pending for $name", 'Y')
		: $self->{pending}  ? ("Nothing to deploy changes on the director for $name", 'G')
		:                     ("Nothing is pending for $name", 'G');
	$colour = 'R' if $f->{drift};
	return ($line, $colour);
}

# }}}
# _write_summary - the summary's paragraphs, plain, to the summary file {{{
sub _write_summary {
	my ($self, @p) = @_;
	mkfile_or_fail($self->{summary_file}, join("\n\n", @p)."\n");
}

# }}}
# }}}

### Helpers {{{

# _section - run one director section, keeping what it says for later {{{
sub _section {
	my ($self, $name, $fn) = @_;
	local $self->{section} = $name;
	$self->{lines}{$name} = [];
	$fn->();
}

# }}}
# _say - keep one line of the current section {{{
sub _say {
	my ($self, @line) = @_;
	push @{$self->{lines}{$self->{section}}}, [@line];
	return;
}

# }}}
# _record - the newest successful deployment record, or undef {{{
sub _record {
	my ($self) = @_;
	$self->{record} = eval {$self->{env}->with_vault->deployments->latest_successful}
		unless exists $self->{record};
	return $self->{record};
}

# }}}
# _provider - the manifest provider, cloud configs downloaded, entombing by name alone {{{
sub _provider {
	my ($self) = @_;
	return $self->{provider} //= $self->{env}->download_required_configs('blueprint', 'manifest')
		->manifest_provider->without_credhub_writes;
}

# }}}
# _current - the branch's pruned deployment manifest, as the deploy would send it {{{
sub _current {
	my ($self) = @_;
	return $self->{current} //= $self->_provider->deployment(subset => 'pruned')->data;
}

# }}}
# _compare - keep one baseline's diff against the branch {{{
sub _compare {
	my ($self, $what, $old, $new, $secrets, $old_label, $new_label, $absent) = @_;
	return $self->_say("[[  >>against %s: #Y{%s}", $what, $absent) unless $old;
	my ($diff) = $self->_diff($old, $new, $secrets, $old_label, $new_label);
	return $self->_say("[[  >>against %s: #G{no differences}", $what) unless $diff;
	$self->{pending}++;
	$self->{facts}{manifest} = 1;
	$self->_say("[[  >>against %s:\n\n%s", $what, $diff);
}

# }}}
# _diff - spruce diff of two manifests, vault values masked unless unredacted {{{
sub _diff {
	my ($self, $old, $new, $secrets, $old_label, $new_label) = @_;
	($old, $new) = _masked($old, $new, $secrets) if $self->{redact};
	return _spruce({object => $old, label => $old_label}, {object => $new, label => $new_label});
}

# }}}
# _config_diff - a config diff, every scalar it changes masked under redaction {{{
#
# The director returns a config as it was uploaded, and a hook can generate
# one with a value in clear, so under redaction a config shows what moved
# and not its values (D123).
sub _config_diff {
	my ($self, $old, $new, $plain) = @_;
	return $plain // _spruce($old, $new) unless $self->{redact};
	my ($o, $n) = map {my $d = eval {load_yaml($_->{content} // '')}; ref $d ? $d : {}} ($old, $new);
	($o, $n) = _mask_changed($o, $n);
	return _spruce({object => $o, label => $old->{label}}, {object => $n, label => $new->{label}});
}

# }}}
# _spruce - spruce_diff's differences, or '' where there are none {{{
#
# The exit code says whether they differ: the pseudo-terminal spruce_diff
# runs under leaves a ^D in the output of an identical pair on macOS.
sub _spruce {
	my ($old, $new) = @_;
	my ($out, $rc, $err) = spruce_diff($old, $new);
	bail("Could not diff %s and %s: %s", $old->{label}, $new->{label}, $err // $out) if $rc > 1;
	return '' unless $rc;
	return ($out // '') =~ s/\^D[\x08]*//gr =~ s/\A\s+|\s+\z//gr;
}

# }}}
# _director_manifest - the live manifest of the deployment, or undef {{{
sub _director_manifest {
	my ($self) = @_;
	my $env = $self->{env};
	my ($out, $rc) = $env->with_bosh->bosh->execute(
		{interactive => 0, deployment => $env->deployment_name}, 'manifest');
	return undef if $rc || !defined $out || $out !~ /\S/;
	my $manifest = eval {load_yaml($out)};
	return ref($manifest) eq 'HASH' ? $manifest : undef;
}

# }}}
# _masked - copies of two manifests with the vault values in clear replaced {{{
#
# An entombed value is its CredHub reference, the name a deploy sends and an
# operator reads, so it is shown and only a value in clear is masked.
sub _masked {
	my ($old, $new, $paths) = @_;
	$old = JSON::PP->new->decode(JSON::PP->new->encode($old));
	$new = JSON::PP->new->decode(JSON::PP->new->encode($new));
	# A reference, or the placeholder for a secret the vault lacks (D129).
	my $ref = qr/^(?:\(\(.*\)\)|<(?:generated on deploy|must be provided|missing)>)$/;
	for my $path (@$paths) {
		my ($o, $n) = (_at($old, $path), _at($new, $path));
		my $same = defined $o && defined $n && JSON::PP->new->canonical->encode([$$o]) eq JSON::PP->new->canonical->encode([$$n]);
		$$n = $same ? $MASK : $MASK_DIFF if $n && ($$n // '') !~ $ref;
		$$o = $MASK if $o && ($$o // '') !~ $ref;
	}
	return ($old, $new);
}

# }}}
# _mask_changed - copies of two documents, every scalar that differs masked {{{
sub _mask_changed {
	my ($old, $new) = @_;
	if (ref $old eq 'HASH' && ref $new eq 'HASH') {
		my ($o, $n, %seen) = ({}, {});
		for my $k (grep {!$seen{$_}++} (keys %$old, keys %$new)) {
			if (exists $old->{$k} && exists $new->{$k}) {
				($o->{$k}, $n->{$k}) = _mask_changed($old->{$k}, $new->{$k});
			} elsif (exists $old->{$k}) {
				$o->{$k} = _mask_all($old->{$k}, $MASK);
			} else {
				$n->{$k} = _mask_all($new->{$k}, $MASK_DIFF);
			}
		}
		return ($o, $n);
	}
	if (ref $old eq 'ARRAY' && ref $new eq 'ARRAY') {
		my ($o, $n) = ([], []);
		for my $i (0 .. ($#$old > $#$new ? $#$old : $#$new)) {
			if ($i <= $#$old && $i <= $#$new) {
				($o->[$i], $n->[$i]) = _mask_changed($old->[$i], $new->[$i]);
			} elsif ($i <= $#$old) {
				$o->[$i] = _mask_all($old->[$i], $MASK);
			} else {
				$n->[$i] = _mask_all($new->[$i], $MASK_DIFF);
			}
		}
		return ($o, $n);
	}
	return ($old, $new) if !ref $old && !ref $new && (defined $old ? defined $new && $old eq $new : !defined $new);
	return (_mask_all($old, $MASK), _mask_all($new, $MASK_DIFF));
}

# }}}
# _mask_all - a copy of a document with every scalar masked {{{
sub _mask_all {
	my ($data, $mask) = @_;
	return {map {($_ => _mask_all($data->{$_}, $mask))} keys %$data} if ref $data eq 'HASH';
	return [map {_mask_all($_, $mask)} @$data] if ref $data eq 'ARRAY';
	return defined $data ? $mask : undef;
}

# }}}
# _at - a reference to the value at a path, or undef where it is absent {{{
sub _at {
	my ($data, $path) = @_;
	my $ref = \$data;
	for my $step (@$path) {
		my $here = $$ref;
		if (ref $here eq 'HASH' && exists $here->{$step}) {
			$ref = \$here->{$step};
		} elsif (ref $here eq 'ARRAY' && $step =~ /^\d+$/ && $step < @$here) {
			$ref = \$here->[$step];
		} else {
			return undef;
		}
	}
	return $ref;
}

# }}}
# _redacted_paths - the paths whose value the redacted manifest hides {{{
sub _redacted_paths {
	my ($data, @at) = @_;
	return () unless defined $data;
	return map {_redacted_paths($data->{$_}, @at, $_)} sort keys %$data if ref $data eq 'HASH';
	return map {_redacted_paths($data->[$_], @at, $_)} 0..$#$data if ref $data eq 'ARRAY';
	return $data =~ /REDACTED/ ? ([@at]) : ();
}

# }}}
# _yaml_artifact - one artifact of a deployment record, parsed, or undef {{{
sub _yaml_artifact {
	my ($record, $type) = @_;
	return undef unless $record && eval {$record->has_artifact($type)};
	my $text = eval {$record->artifact($type)};
	return defined $text && $text =~ /\S/ ? load_yaml($text) : undef;
}

# }}}
# _json - a director API answer, decoded, or undef {{{
sub _json {
	my ($bosh, $path) = @_;
	my ($out, $rc) = $bosh->execute({interactive => 0}, 'curl', $path);
	return undef if $rc || !defined $out || $out !~ /\S/;
	return eval {JSON::PP->new->decode($out)};
}

# }}}
# _message - a commit's full message, or undef {{{
sub _message {
	my ($git, $sha) = @_;
	my ($out, $rc) = run({dir => $git->root, stderr => 0}, 'git', 'log', '-1', '--format=%B', $sha);
	return $rc ? undef : $out;
}

# }}}
# _meta - a commit's author, time and subject, or undef where this clone lacks it {{{
sub _meta {
	my ($git, $sha) = @_;
	my ($out, $rc) = run({dir => $git->root, stderr => 0},
		'git', 'log', '-1', '--format=%an%x1f%at%x1f%s', "$sha^{commit}");
	return undef if $rc || !defined $out || $out !~ /\x1f/;
	chomp $out;
	my ($author, $epoch, $subject) = split /\x1f/, $out, 3;
	return {author => $author, epoch => $epoch, subject => $subject};
}

# }}}
# _stat - the diff stat from a base to HEAD under the deployment root {{{
#
# Drawn to the output's width less the report's indent, and no wider than
# 120, so git shortens the bar rather than the output wrapping it.
sub _stat {
	my ($git, $base) = @_;
	my $width = terminal_width() - 2;
	$width = 120 if $width > 120;
	my ($out, $rc) = run({dir => $git->root, stderr => 0}, 'git', 'diff', "--stat=$width",
		($git->prefix ? ('--relative='.$git->prefix) : ()), $base // $EMPTY_TREE, 'HEAD');
	return () if $rc || !defined $out;
	return grep {/\S/} split /\n/, $out;
}

# }}}
# _stat_files - how many files a diff stat names {{{
sub _stat_files {
	my ($stat) = @_;
	return 0 unless @$stat;
	return $stat->[-1] =~ /^\s*(\d+) files? changed/ ? $1 : scalar(@$stat) - 1;
}

# }}}
# _norm - a subject with its version strings and shas replaced, for folding runs {{{
sub _norm {
	my ($subject) = @_;
	$subject //= '';
	$subject =~ s/\d+(?:\.\d+)+[-+.\w]*/…/g;
	$subject =~ s/\b[0-9a-f]{7,40}\b/…/g;
	return $subject;
}

# }}}
# _count - "N thing(s)", or nothing for none {{{
sub _count {
	my ($n, $one, $many) = @_;
	return () unless $n;
	return sprintf('%d %s', $n, $n == 1 ? $one : ($many // "${one}s"));
}

# }}}
# _day, _stamp, _ago - a commit time, as a day, a timestamp, and how long ago {{{
#
# The fuzzy form is read from the seconds elapsed, the one input
# strfuzzytime takes without parsing a date string.
sub _day   {return POSIX::strftime('%b %-d', localtime($_[0]))}
sub _stamp {return defined $_[0] ? POSIX::strftime('%b %d %H:%M', localtime($_[0])) : '?'}
sub _ago   {
	my $delta = time - $_[0];
	return $delta < 0 ? 'in the future' : strfuzzytime(Time::Seconds->new($delta)).' ago';
}

# }}}
# _width - the frame's width: the terminal's, no wider than a page {{{
sub _width {
	my $w = terminal_width();
	return $w < $RULE_WIDTH ? $w : $RULE_WIDTH;
}

# }}}
# _frame - a summary frame line, or the closing verdict in its style {{{
sub _frame {
	my ($title, $colour) = @_;
	my $line = defined $title ? "══ $title " : '';
	$line .= '═' x (_width() - length $line) if length($line) < _width();
	info("\n#%s{%s}", $colour // 'K', $line);
}

# }}}
# _rule - the labelled rule between the git half and the director's {{{
sub _rule {
	my ($label) = @_;
	my $line = "── $label ";
	$line .= '─' x (_width() - length $line) if length($line) < _width();
	info("\n#K{%s}", $line);
}

# }}}
# _heading - one section's heading {{{
sub _heading {
	info("\n#Gu{%s}", $_[0]);
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
