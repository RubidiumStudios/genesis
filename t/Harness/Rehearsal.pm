package Harness::Rehearsal;

# A stand-in for Concourse's scheduler, running a compiled pipeline's jobs
# against a harness until nothing triggers.  See Harness/Rehearsal.pod.

use strict;
use warnings;

use Exporter qw/import/;
use Genesis qw/run/;
use Harness::Propagation;

our @EXPORT = qw/rehearsal/;

sub rehearsal {
	my ($h, $pipeline, %opts) = @_;
	my $self = bless {
		h        => $h,
		pipeline => $pipeline,
		work     => "$h->{tmp}/rehearsal",
		max      => $opts{max} // 20,
		seen     => {},   # job => {resource => version}
		shuttle  => {},   # resource => version
		pools    => {},   # pool => {key => ..., holders => {by => 1}}
		parked   => {},   # job => pool
		runs     => [],
	}, __PACKAGE__;
	$self->mark_seen;
	return $self;
}

sub _job      {my ($self, $name) = @_; (grep {$_->{name} eq $name} @{$self->{pipeline}{jobs}})[0]}
sub _resource {my ($self, $name) = @_; (grep {$_->{name} eq $name} @{$self->{pipeline}{resources}})[0]}

sub version {
	my ($self, $name) = @_;
	my $res = $self->_resource($name) or die "rehearsal: no resource $name\n";
	return remote_sha($self->{h}, $res->{source}{branch}) if $res->{type} eq 'git';
	return $self->{shuttle}{$name} // 0 if $res->{type} eq 'shuttle';
	die "rehearsal: no versions for a $res->{type} resource\n";
}

# Every step of a plan node, in order, flattened through do and in_parallel.
sub _steps {
	my ($node) = @_;
	return () unless ref $node;
	return map {_steps($_)} @$node if ref $node eq 'ARRAY';
	return _steps($node->{do})          if $node->{do};
	return _steps($node->{in_parallel}) if $node->{in_parallel};
	return $node;
}

sub _triggers {
	my ($self, $job) = @_;
	return map {$_->{get}} grep {$_->{get} && $_->{trigger}}
		map {_steps($_->{do} ? $_->{do} : $_)} @{$job->{plan}};
}

sub mark_seen {
	my ($self) = @_;
	for my $job (@{$self->{pipeline}{jobs}}) {
		$self->{seen}{$job->{name}}{$_} = $self->version($_) for $self->_triggers($job);
	}
	return $self;
}

sub _due {
	my ($self, $job) = @_;
	return 0 if $self->{parked}{$job->{name}} && !$self->_free_for(@{$self->{parked}{$job->{name}}});
	return scalar grep {($self->{seen}{$job->{name}}{$_} // '') ne $self->version($_)} $self->_triggers($job);
}

sub settle {
	my ($self) = @_;
	for (1 .. $self->{max}) {
		my ($job) = grep {$self->_due($_)} @{$self->{pipeline}{jobs}};
		return $self unless $job;
		$self->_run_job($job);
	}
	die "rehearsal: still triggering after $self->{max} runs\n";
}

# Locks, keyed as the locker resource keys them: one key at a time per pool,
# held by any number of holders of that key.
sub _pool_of {my ($self, $res) = @_; $self->_resource($res)->{source}{lock_name}}
sub _free_for {
	my ($self, $pool, $key) = @_;
	my $p = $self->{pools}{$pool};
	return !$p || !%{$p->{holders}} || $p->{key} eq $key;
}
sub hold {
	my ($self, $pool, $key, $by) = @_;
	die "rehearsal: $pool is held under $self->{pools}{$pool}{key}\n" unless $self->_free_for($pool, $key);
	$self->{pools}{$pool}{key} = $key;
	$self->{pools}{$pool}{holders}{$by} = 1;
	return $self;
}
sub release {
	my ($self, $pool, $key, $by) = @_;
	my $p = $self->{pools}{$pool};
	die "rehearsal: $by holds no $key on $pool\n" unless $p && $p->{key} eq $key && $p->{holders}{$by};
	delete $p->{holders}{$by};
	delete $self->{pools}{$pool} unless %{$p->{holders}};
	return $self;
}
sub held {my ($self) = @_; return {map {($_ => $self->{pools}{$_}{key})} keys %{$self->{pools}}}}

sub _run_job {
	my ($self, $job) = @_;
	my $name = $job->{name};
	my %run  = (job => $name, commands => [], puts => []);
	my $dir  = "$self->{work}/$name";
	run({}, 'rm', '-rf', $dir);
	helper::mkdir_or_fail($dir);

	my %got;
	my $outcome = 'success';
	for my $node (@{$job->{plan}}) {
		for my $step (_steps($node->{do} ? $node->{do} : $node)) {
			if (my $put = $step->{put}) {
				my $res = $self->_resource($put);
				if ($res->{type} eq 'locker') {
					my ($pool, $key) = ($self->_pool_of($put), $step->{params}{key});
					if ($step->{params}{lock_op} eq 'lock' && !$self->_free_for($pool, $key)) {
						$self->{parked}{$name} = [$pool, $key];
						$self->_unwind($node, \%run);   # what it took before parking
						push @{$self->{runs}}, {%run, outcome => 'parked', parked_on => $pool};
						return;
					}
					$step->{params}{lock_op} eq 'lock'
						? $self->hold($pool, $key, $step->{params}{locked_by})
						: $self->release($pool, $key, $step->{params}{locked_by});
				}
				push @{$run{puts}}, $put;
			} elsif (my $get = $step->{get}) {
				my $res = $self->_resource($get);
				$got{$get} = $self->version($get);
				$self->_checkout($res, "$dir/$get", $got{$get}) if $res->{type} eq 'git';
			} elsif ($step->{task}) {
				my $c = $step->{config};
				my ($out, $err, $rc) = $self->{h}->run_task(dir => "$dir/$c->{run}{dir}",
					path => $c->{run}{path}, args => $c->{run}{args}, params => $c->{params});
				push @{$run{commands}}, {argv => [$c->{run}{path}, @{$c->{run}{args} || []}],
					dir => $c->{run}{dir}, rc => $rc, out => $out, err => $err};
				if ($rc) { $outcome = 'failure'; last }
			}
		}
		last if $outcome ne 'success';
	}

	my ($top) = @{$job->{plan}};
	$self->_put_all($top->{"on_$outcome"}, \%run) if ref $top eq 'HASH';
	$self->_put_all($top->{ensure}, \%run) if ref $top eq 'HASH';
	delete $self->{parked}{$name};
	$self->{seen}{$name}{$_} = $got{$_} for grep {exists $got{$_}} $self->_triggers($job);
	push @{$self->{runs}}, {%run, outcome => $outcome};
}

# As the git resource gets a version: that branch alone, at the version's
# commit, with HEAD detached.
sub _checkout {
	my ($self, $res, $dir, $version) = @_;
	run({onfailure => "rehearsal: cannot check $res->{name} out"}, 'git', 'clone', '-q',
		'--single-branch', '-b', $res->{source}{branch}, "file://$self->{h}{r}", $dir);
	run({dir => $dir, onfailure => "rehearsal: cannot check $res->{name} out at $version"},
		'git', 'checkout', '-q', $version);
}

sub _put_all {
	my ($self, $node, $run) = @_;
	for my $step (_steps($node)) {
		my $put = $step->{put} or next;
		my $res = $self->_resource($put);
		if ($res->{type} eq 'shuttle') {
			$self->{shuttle}{$put}++;
		} elsif ($res->{type} eq 'locker') {
			$step->{params}{lock_op} eq 'lock'
				? $self->hold($self->_pool_of($put), $step->{params}{key}, $step->{params}{locked_by})
				: $self->release($self->_pool_of($put), $step->{params}{key}, $step->{params}{locked_by});
		}
		push @{$run->{puts}}, $put;
	}
}

# A job that parks releases what it took, as its ensure would on abort.
sub _unwind {
	my ($self, $node, $run) = @_;
	for my $step (_steps($node->{ensure})) {
		next unless $step->{put} && ($step->{params}{lock_op} // '') eq 'unlock';
		my ($pool, $key, $by) = ($self->_pool_of($step->{put}), @{$step->{params}}{qw/key locked_by/});
		my $p = $self->{pools}{$pool};
		$self->release($pool, $key, $by) if $p && $p->{key} eq $key && $p->{holders}{$by};
	}
}

sub runs {@{$_[0]{runs}}}
sub jobs_run {map {$_->{job}} grep {$_->{outcome} ne 'parked'} @{$_[0]{runs}}}

1;
