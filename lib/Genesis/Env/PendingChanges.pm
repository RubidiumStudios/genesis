package Genesis::Env::PendingChanges;
use strict;
use warnings;

use Genesis;
use Genesis::CI::Marker ();
use JSON::PP ();

# What deploying an environment's branch would change, read-only (D123).
# See PendingChanges.pod.

my $MASK      = '<redacted>';
my $MASK_DIFF = '<redacted: changed>';

### Class Methods {{{

# new - a report for one loaded environment {{{
sub new {
	my ($class, $env, %opts) = @_;
	return bless {env => $env, redact => $opts{redact} ? 1 : 0, pending => 0}, $class;
}

# }}}
# }}}

### Instance Methods {{{

# report - print the four sections and answer whether anything is pending {{{
sub report {
	my ($self) = @_;
	$self->_commits;
	$self->_manifest;
	$self->_configs;
	$self->_uploads;
	info("\n%s", $self->{pending}
		? "#Y{Changes are pending for} #C{".$self->{env}->name."}#Y{.}"
		: "#G{Nothing is pending for} #C{".$self->{env}->name."}#G{.}");
	return $self->{pending};
}

# }}}
# }}}

### Sections {{{

# _commits - the branch's commits since the deployed one {{{
sub _commits {
	my ($self) = @_;
	my $env = $self->{env};
	my $git = $env->top->git;
	my $deployed = ($env->deployed_record // {})->{git}{commit};

	_heading('Commits since the last deploy');
	my $range = 'HEAD';
	if (!$deployed) {
		info("[[  >>#Y{%s has never been deployed}; the branch holds:", $env->name);
	} elsif (!$git->is_ancestor($deployed, 'HEAD')) {
		info("[[  >>#Y{the deployed commit %s is not on this branch}; the branch holds:",
			substr($deployed, 0, 8));
	} else {
		$range = "$deployed..HEAD";
	}

	my @commits = $git->log_subjects($range, body => 1);
	return info("[[  >>#G{none}") unless @commits;
	$self->{pending}++;

	my @scope = $git->prefix ? ($git->prefix) : ();
	for my $commit (@commits) {
		my ($subject) = split /\n/, $commit->{message};
		my ($control) = Genesis::CI::Marker::in_text($commit->{message});
		info("[[  - >>#C{%s} %s %s", substr($commit->{sha}, 0, 8),
			  defined $control ? "#G{propagated} from control\@".substr($control, 0, 8)
			: Genesis::CI::Marker::is_seed($commit->{message}) ? '#K{seed}'
			: '#Y{manual}',
			$subject);
		info("[[      >>%s", $_) for $git->commit_files($commit->{sha}, @scope);
	}
}

# }}}
# _manifest - the branch's manifest against the director's and exodus's {{{
sub _manifest {
	my ($self) = @_;
	my $env = $self->{env};
	_heading('Manifest');

	my $provider = $self->_provider;
	my $current  = $self->_current;
	my @secrets  = _redacted_paths(eval {$provider->redacted(subset => 'pruned')->data});

	my $record   = eval {$env->with_vault->deployments->latest_successful};
	my $exodus   = _yaml_artifact($record, 'manifest');
	my $director = $env->use_create_env ? undef : $self->_director_manifest;

	# A first deploy: nothing anywhere to compare with, so the whole manifest
	# is the change, shown as additions against an empty one.
	unless ($director || $exodus) {
		$self->_compare('nothing deployed, a first deploy', {}, $current, \@secrets,
			'nothing', 'branch', '');
		return;
	}

	if ($env->use_create_env) {
		info("[[  >>a create-env environment has no director; comparing with the last deploy alone.");
	} else {
		$self->_compare('the director\'s live manifest', $director, $current, \@secrets,
			'director', 'branch', 'the director holds no manifest for '.$env->deployment_name);
	}
	$self->_compare('the last manifest Genesis deployed (exodus)', $exodus, $current, \@secrets,
		'exodus', 'branch', 'no deployed manifest is recorded in exodus');

	if ($director && $exodus) {
		my ($diff) = $self->_diff($exodus, $director, \@secrets, 'exodus', 'director');
		info("[[  >>#R{drift:} the director's manifest differs from the last one Genesis ".
			"deployed, so something was deployed outside Genesis:\n\n%s", $diff) if $diff;
	}

	my $vars = eval {$provider->deployment(subset => 'bosh_vars')->data};
	if ($vars && %$vars) {
		my @var_secrets = _redacted_paths(eval {$provider->redacted(subset => 'bosh_vars')->data});
		$self->_compare('the last deployed BOSH variables', _yaml_artifact($record, 'vars'),
			$vars, \@var_secrets, 'exodus', 'branch', 'no deployed BOSH variables are recorded');
	}
}

# }}}
# _configs - configs the deploy would upload, and those moved on the director {{{
sub _configs {
	my ($self) = @_;
	my $env = $self->{env};
	_heading('BOSH configs');
	return info("[[  >>a create-env environment uses no director configs.") if $env->use_create_env;

	my $bosh = $env->with_bosh->bosh;
	require Genesis::Commands::Bosh;
	my ($configs, $notes) = Genesis::Commands::Bosh::_bosh_configs_provided($env, $bosh);
	my $said = 0;
	for my $config (@$configs) {
		my $status = Genesis::Commands::Bosh::_bosh_configs_status($config);
		next if $status eq 'identical';
		$self->{pending}++; $said++;
		info("[[  - >>%s config %s would be uploaded (%s on the director)%s",
			$config->{type}, $config->{name}, $status eq 'missing' ? 'missing' : 'different',
			$config->{diff} ? ":\n\n$config->{diff}" : '');
	}

	my $ran    = _json($bosh, '/deployment_configs?deployment='.$env->deployment_name) || [];
	my $latest = _json($bosh, '/configs?latest=true') || [];
	my %ran    = map {my $c = $_->{config} || {}; ("$c->{type}/$c->{name}" => $c->{id})} @$ran;
	for my $config (sort {"$a->{type}/$a->{name}" cmp "$b->{type}/$b->{name}"}
	                grep {$_->{type} =~ /^(cloud|runtime)$/} @$latest) {
		my $key = "$config->{type}/$config->{name}";
		if (!exists $ran{$key}) {
			next unless @$ran;
			$self->{pending}++; $said++;
			info("[[  - >>%s config %s is new on the director since the last deploy:\n\n%s",
				$config->{type}, $config->{name}, $config->{content} // '');
		} elsif ($ran{$key} ne $config->{id}) {
			my $old = (_json($bosh, "/configs/$ran{$key}") || {})->{content} // '';
			my $diff = _spruce({content => $old, label => "id $ran{$key}"},
				{content => $config->{content} // '', label => "id $config->{id}"});
			$self->{pending}++; $said++;
			info("[[  - >>%s config %s changed on the director since the last deploy:\n\n%s",
				$config->{type}, $config->{name}, $diff);
		}
	}
	info("[[  >>#G{none}") unless $said;
}

# }}}
# _uploads - releases and stemcells the director lacks {{{
sub _uploads {
	my ($self) = @_;
	my $env = $self->{env};
	_heading('Uploads');
	return info("[[  >>a create-env environment uploads nothing to a director.") if $env->use_create_env;

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
	return info("[[  >>#G{none}") unless @missing;
	$self->{pending}++;
	info("[[  - >>the deploy would upload %s", $_) for @missing;
}

# }}}
# }}}

### Helpers {{{

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
# _compare - print one baseline's diff against the branch {{{
sub _compare {
	my ($self, $what, $old, $new, $secrets, $old_label, $new_label, $absent) = @_;
	return info("[[  >>against %s: #Y{%s}", $what, $absent) unless $old;
	my ($diff) = $self->_diff($old, $new, $secrets, $old_label, $new_label);
	return info("[[  >>against %s: #G{no differences}", $what) unless $diff;
	$self->{pending}++;
	info("[[  >>against %s:\n\n%s", $what, $diff);
}

# }}}
# _diff - spruce diff of two manifests, vault values masked unless unredacted {{{
sub _diff {
	my ($self, $old, $new, $secrets, $old_label, $new_label) = @_;
	($old, $new) = _masked($old, $new, $secrets) if $self->{redact};
	return _spruce({object => $old, label => $old_label}, {object => $new, label => $new_label});
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
	my $ref = qr/^\(\(.*\)\)$/;
	for my $path (@$paths) {
		my ($o, $n) = (_at($old, $path), _at($new, $path));
		my $same = defined $o && defined $n && JSON::PP->new->canonical->encode([$$o]) eq JSON::PP->new->canonical->encode([$$n]);
		$$n = $same ? $MASK : $MASK_DIFF if $n && ($$n // '') !~ $ref;
		$$o = $MASK if $o && ($$o // '') !~ $ref;
	}
	return ($old, $new);
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
# _heading - one section's heading {{{
sub _heading {
	info("\n#Gu{%s}", $_[0]);
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
