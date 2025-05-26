package Genesis::Env::DeploymentManager;

use strict;
use warnings;
use 5.20.0;

use Genesis qw/bail debug bug unflatten in_array EXODUS_TIME_FORMAT EXODUS_TIME_FORMAT_SHORT/;
use Genesis::Env::Deployment;

use Time::Piece;
use Time::HiRes qw/gettimeofday/;
use Time::Seconds qw/ONE_DAY/;

# Create a new deployment manager for the given environment
sub new {
	my ($class, $env) = @_;
	return bless {
		env => $env,
		deployments_cache => undef
	}, $class;
}

# Get all deployment audits - returns array
sub all {
	my ($self) = @_;
	my $env = $self->{env};
	return @{$self->{deployments_cache}} if $self->{deployments_cache};
	
	# Get list of deployments from vault
	my $deployments = $env->vault->get_path($env->exodus_base.'/deployments');
	return () unless $deployments && %$deployments;

	# Create a new deployment object for each deployment
	my @deployments = map {
		Genesis::Env::Deployment->new(
			$env,
			timestamp => $_,
			%{$deployments->{$_}}
		)
	} sort {$b cmp $a} keys %{$deployments};
	
	$self->{deployments_cache} = \@deployments;
	return @deployments;
}

# Reset the cached deployments
sub reset {
	$_[0]->{deployments_cache} = undef;
}

# Find matching deployment audits
sub find {
	my ($self, %options) = @_;
	# Valid options:
	# - action: filter by action (deploy/terminate)
	# - result: filter by result (success/failed/pending/post-failed)
	# - all: include pending and failed deployments (by default, only successful ones are returned)
	# - timestamps_only: return only timestamps (no deployment objects)
	# - limit: limit the number of deployments returned (latest N deployments)
	# - range: compare with a specific timestamp fragment, ie '<20230101' or '>=2025'
	
	my $env = $self->{env};

	my @invalid_options = grep { !/^(action|result|all|timestamps_only|limit|range)$/ } keys %options;
	bail {
		"Invalid options: %s",
		join(", ", @invalid_options)
	} if @invalid_options;
	$options{all} = 1 if $options{result}; # If result is specified, include all deployments
	
	# Get list of deployments
	my @all_deployments = $self->all();
	return () unless @all_deployments;

	# Filter by range if specified
	my $picks = undef;
	if ($options{range}) {
		my $range = $options{range};
		# Supports the following formats:
		# - [<|>|<=|>=]<timestamp>
		# - <timestamp>[<|<=]x[<|<=]<timestamp>
		# - N[...M] (where N and M are integer offsets, negative for reverse)
		# where <timestamp> is 'YYYY[-?MM[-?DD[T| ][HH[:?MM[:?SS[Z| ][+-]HHMM]]]]]'
		if ($range =~ /^(-?\d+)(?:\.\.\.(-?\d+))?$/) {
			my ($start, $end) = ($1, $2);
			$end //= $start;
			# This gets applied after all the other filters, just store it for now
			$picks = $start < $end ? [$start..$end] : [reverse($end..$start)];
		} else {
			my ($before, $after) = ();
			if ($range =~ /^(.*?)(<(?:=?)x<(?:=?))(.*?)$/) {
				# Format: <timestamp><x<timestamp> or <timestamp><=x<=timestamp>
				my ($low, $separator, $high) = ($1, $2, $3);
				my ($loweql, $higheql) = $separator =~ /<(=?)x<(=?)/;
				$after = _parse_into_timestamp_cmp($low, '>'.$loweql);
				$before = _parse_into_timestamp_cmp($high, '<'.$higheql);
			} elsif ($range =~ /^([<>])(=?)(\d.*)$/) {
				my ($cmp, $eq, $ts) = ($1, $2, $3);
				if ($cmp eq '<') {
					$before = _parse_into_timestamp_cmp($ts, '<'.$eq);
				} elsif ($cmp eq '>') {
					$after = _parse_into_timestamp_cmp($ts, '>'.$eq);
				}
			} else {
				bail(
					"Invalid range format: %s",
					$range
				)
			}

			# Step through the deployments until you reach the before, then stop after the after
			my @deployments_in_range = ();
			my $idx = 0;

			# Step through the deployments until you reach the before if before is given
			while ($before) {
				last unless $idx < @all_deployments; # We're done if there are no more deployments
				last if $all_deployments[$idx]->timestamp lt $before; # Stop skipping if we are now before the before
				$idx++;
			}

			# Now step through the deployments until you reach the after or the end
			while (1) {
				last unless $idx < @all_deployments; # We're done if there are no more deployments
				last if $after && $all_deployments[$idx]->timestamp gt $after; # Stop if we are now after the after
				push @deployments_in_range, $all_deployments[$idx]; # This is in range
				$idx++;
			}
			@all_deployments = @deployments_in_range;
		}
	}

	# Filter by action if specified
	if ($options{action}) {
		my $action = $options{action};
		@all_deployments = grep { $_->lookup('action') eq $action } @all_deployments;
	}

	# Filter by result if specified
	if ($options{result}) {
		my $result = $options{result};
		@all_deployments = grep { $_->lookup('result') eq $result } @all_deployments;
	}

	# Limit to successful deployments if not all
	if (!$options{all}) {
		@all_deployments = grep {
			in_array($_->lookup('result'), 
				$_->action_succeeded,
				$_->action_post_failed
			)
		} @all_deployments;
	}

	# Filter by picks if given
	@all_deployments = reverse((reverse @all_deployments)[@$picks]) if ($picks);

	# Limit the number of deployments if specified
	@all_deployments = splice(@all_deployments, 0, $options{limit}) if $options{limit};

	return $options{timestamps_only} 
		? map { $_->timestamp } @all_deployments
		: @all_deployments;
}

# Get a deployment audit at a specific timestamp
sub at {
	my ($self, $timestamp) = @_;
	my @deployments = $self->all();
	return undef unless @deployments;

	my ($ts_deployment) = grep {
		$_->{timestamp} eq $timestamp;
	} @deployments;
	return $ts_deployment;
}

# Get most recent deployment audit
sub latest {
	my ($self, %options) = @_;
	my @deployments = $self->all();
	return undef unless @deployments;
	
	for my $deployment (@deployments) {
		next if $options{action} && $deployment->lookup('action') ne $options{action};
		next if $options{result} && $deployment->lookup('result') ne $options{result};
		next if !$options{include_failed} && $deployment->lookup('result') eq $deployment->action_failed;
		return $deployment;
	}
	return undef;
}

# Create a new deployment audit
sub create {
	my ($self, %options) = @_;
	my $env = $self->{env};
	
	my $timestamp = $options{timestamp} // gettimeofday;
	
	# Create deployment data
	my %data = (
		action => $options{action} // 'deploy',
		result => $options{result} // Genesis::Env::Deployment::action_pending(),
		started => $options{started} // time,
		completed => $options{completed} // time,
		sequence => $options{sequence} // 1,
		genesis_version => $options{genesis_version} // $Genesis::VERSION,
		reason => $options{reason} // '',
		kit => $options{kit} // {
			id => $env->kit->id,
			name => $env->kit->name,
			version => $env->kit->version,
			is_dev => $env->kit->is_dev,
			features => [$env->features],
		},
		user => $options{user} // {
			shell => $ENV{SHELL} // '/bin/sh',
			repo => $env->top->name,
			vault => $env->vault->name,
		},
	);
	
	# Store artifacts if provided
	# TODO: Should we build this here, or allow the caller to pass it in?
	if ($options{artifacts}) {
		$data{artifacts} = $options{artifacts};
	}
	
	# Create and return new deployment object
	my $deployment = Genesis::Env::Deployment->new(
		$env,
		timestamp => $timestamp,
		%data
	);
	
	# Save to vault (implemented in Deployment class)
	$deployment->commit();
	
	# Reset cache
	$self->reset();
	
	return $deployment;
}

### Private Instance Methods

### Private Package Functions

sub _get_last_day_of_month {
	my ($year, $month) = @_;
	# Create the first day of the next month
	my $next_month = ($month == 12)
		? Time::Piece->strptime(($year + 1) . "-01-01", "%Y-%m-%d")
		: Time::Piece->strptime($year . "-" . sprintf("%02d", $month + 1) . "-01", "%Y-%m-%d");
	return ($next_month - ONE_DAY)->day_of_month;
}

sub _parse_into_timestamp_cmp {
	my ($ts, $cmp_op) = @_;
	my ($ty,$tm,$td,$tH,$tM,$tS,$tz) = (
		$ts =~ /(\d{4})(?:-?(\d{2})(?:-?(\d{2})(?:[T ]?(\d{2})(?::?(\d{2})(?::?(\d{2})(?:[Z ]?([+-]\d{4}))?)?)?)?)?)?$/
	);
	my $gt = $cmp_op =~ /^>/ ? 1 : 0;
	my $eq = $cmp_op =~ /=$/ ? 1 : 0;
	my ($dm,$dd,$dH,$dM,$dS,$dtz) = $gt
	? (12, $tm ? _get_last_day_of_month($ty,$tm) : 31, 23, 59, 59, '+0000')
	: (1, 1, 0, 0, 0, '+0000');
	my $time = Time::Piece->strptime(
		sprintf(
			"%04d-%02d-%02d %02d:%02d:%02d %s",
			$ty, $tm//$dm, $td//$dd, $tH//$dH, $tM//$dM, $tS//$dS, $tz//$dtz
		),
		EXODUS_TIME_FORMAT
	);
	$time += $eq ? ($gt ? -1 : 1) : 0;
	my $ts_str = $time->gmtime($time->epoch)->strftime(EXODUS_TIME_FORMAT_SHORT);
	return $ts_str;
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
