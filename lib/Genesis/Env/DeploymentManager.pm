package Genesis::Env::DeploymentManager;

use strict;
use warnings;
use 5.20.0;

use Genesis qw/
	bail debug bug
	flatten unflatten in_array deep_merge
	parse_fixed_width_table
	run lines
	EXODUS_TIME_FORMAT EXODUS_TIME_FORMAT_SHORT
/;
use Genesis::Env::Deployment;
use Genesis::Term;

use Digest::file qw/digest_file_hex/;
use JSON::PP qw//;
use Time::Piece;
use Time::HiRes qw/gettimeofday/;
use Time::Seconds qw/ONE_DAY/;

# new - create a new deployment manager for the given environment {{{
sub new {
	my ($class, $env) = @_;
	return bless {
		env => $env,
		deployments_cache => undef
	}, $class;
}
# }}}

# all - get all deployment audits (returns array) {{{
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
# }}}

# reset - reset the cached deployments {{{
sub reset {
	$_[0]->{deployments_cache} = undef;
}
# }}}

# find - find matching deployment audits {{{
sub find {
	my ($self, %options) = @_; # See POD for valid options
	
	my $env = $self->{env};

	# Validate options
	my @invalid_options = grep { !/^(action|result|all|timestamps_only|limit|range)$/ } keys %options;
	bail(
		"Invalid options: %s",
		join(", ", @invalid_options)
	) if @invalid_options;
	$options{all} = 1 if $options{result}; # If result is specified, include all deployments
	
	# Get list of deployments
	my @all_deployments = $self->all();
	return () unless @all_deployments;

	# Filter by range if specified
	my $picks = undef;
	if ($options{range}) {
		my $range = $options{range}; # See POD for valid formats
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
	@all_deployments = grep {
		$_->lookup('action') eq $options{action}
	} @all_deployments if $options{action};

	# Filter by result if specified
	@all_deployments = grep {
		$_->lookup('result') eq $options{result}
	} @all_deployments if $options{result};

	# Limit to successful deployments if not all
	@all_deployments = grep {
		$_->succeeded
	} @all_deployments unless ($options{all});

	# Filter by picks if given
	@all_deployments = reverse(
		(reverse @all_deployments)[@$picks]
	) if ($picks);

	# Limit the number of deployments if specified
	@all_deployments = splice(
		@all_deployments, 0, $options{limit}
	) if $options{limit};

	return $options{timestamps_only}
		? map { $_->timestamp } @all_deployments
		: @all_deployments;
}
# }}}

# at - get a deployment audit at a specific timestamp {{{
sub at {
	my ($self, $timestamp) = @_;
	my @deployments = $self->all();
	return undef unless @deployments;

	my ($ts_deployment) = grep {
		$_->{timestamp} eq $timestamp;
	} @deployments;
	return $ts_deployment;
}
# }}}

# latest - get most recent deployment audit {{{
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
# }}}

# latest_successful - get the latest successful deployment {{{
sub latest_successful {
	my ($self, %options) = @_;
	# Get the latest successful deployment - find by default will return only successful actions
	
	my ($latest_successful) = $self->find(%options,limit => 1);
	return $latest_successful;
}
# }}}

# current_state - determine the current deployment state of the environment {{{
sub current_state {
	my ($self) = @_;
	# FIXME: Need to handle exodus-only based deployment definitions if we're not using audits
	# FIXME: Cache, and clear on reset;
	for my $deployment ($self->find()) {
		if ($deployment->succeeded) {
			return $deployment->action eq 'deploy' ? 'deployed' : 'terminated';
		}
	}
	return 'undeployed';
}
# }}}

# build - build a new deployment audit object {{{
sub build {
	my ($self, $action, $result, %options) = @_;
	my $env = $self->{env};

	# TODO: Do we strip the timestamp and sequence number from the options,
	#       as they are set on commit?  Or should they (or at least the timestamp)
	#       be allowed to be set by the caller?

	# Merge in deployment contents to base deployment data
	my $base_content = $self->_base_deployment_content($action, $result);
	my $data = deep_merge($base_content, \%options);

	return Genesis::Env::Deployment->new($env, %$data);
}
# }}}

# next_sequence_number - get the next sequence number for deployments {{{
sub next_sequence_number {
	my ($self, $action) = @_;
	# Get the latest deployment for the given action
	my $latest = $self->latest();
	return 1 unless $latest; # If no deployments, return 1
	return scalar($self->all)+1 unless $latest->sequence;
	return $latest->sequence + 1; # Return the next sequence number
}
# }}}

# REFACTOR: This is the old get_next_deployment_sequence_number from Genesis::Env from before it was broken out
# to the Genesis::Env::Deployment and Genesis::Env::DeploymentManager classes.  It has a more complex
# logic to handle backfilling the deployment audit data, so it is kept here for now as a POD block, but it,
# and the _backfill_deployment_audit_data method, needs to be re-analyzed and and determined if it is still
# needed, and in what capacity.

=old_code
# get_next_deployment_sequence_number - get the next deployment sequence number {{{
sub get_next_deployment_sequence_number {
	my ($self) = @_;

	my $old_exodus = $self->exodus_lookup(".",{});
	my $sequence = $old_exodus->{sequence};
	return $sequence + 1 if defined($sequence);

	# If sequence is not found, then an older version of Genesis was used and we
	# need to figure out if we need to backfill the deployment audit data

	# If the manifest store is the repository, then we can't backfill the
	# deployment audit data because that isn't supported, so just assume 1;
	return 1 if ($self->manifest_store eq 'repository');

	# If there were no deployment audits, then we can start at 1
	my $last_deployment = $self->deployment_lookup('latest');
	return 1 unless $last_deployment;

	# If the last deployment was terminated, then we can start at one more than
	# the termination sequence number
	return $last_deployment->{sequence} + 1
		if ($last_deployment->{state}//'deployed') eq 'terminated'
		&& defined($last_deployment->{sequence});

	# If the last deployment was not terminated, then we need to backfill the
	# deployment audit data to ensure that the sequence numbers are correct
	$last_deployment = $self->_backfill_deployment_audit_data(
		$old_exodus, $last_deployment
	);
	return $last_deployment->{sequence} + 1;
}
# _backfill_deployment_audit_data - backfill the audit data for a missing deployment or termination {{{
sub _backfill_deployment_audit_data {
	# REFACTOR: Move this to the deployments class?
	my ($self, $old_exodus, $latest_deployment) = @_;

	# Get last deployments sequence number
	$latest_deployment //= $self->deployments->latest();

	return undef unless $latest_deployment || keys %$old_exodus; # no prior deployments
	my $sequence = $self->deployments->get_sequence_number;

	# Case 1: We have no data in exodus, so it must have been terminated
	if (!keys %$old_exodus) {
		return $last_deployment if $self->deployments->current_state eq 'terminated';

		# Create an artificial termination date halfway between the last
		# deployment and now
		my $now = Time::Piece->new;
		my $termination_time = Time::Piece->strptime(
			$last_deployment->completed || $last_deployment->lookup('dated') || $now->strftime(EXODUS_TIME_FORMAT),
			EXODUS_TIME_FORMAT
		);

		$self->deployments->build(
			terminate => 'assumed',
			started => $termination_time->strftime(EXODUS_TIME_FORMAT),
			completed => $now->strftime(EXODUS_TIME_FORMAT),
			reason => 'Terminated via unknown means after last recorded deployment (time unknown)',
		)->commit();
		return $self->deployments->latest();

	# Case 2: We have data in exodus, but no sequence number, so we need to
	# backfill the deployment audit data
	} else {

		# Sanity check: if exodus has a sequence number, then we don't need to
		# backfill the deployment audit data
		if (defined($old_exodus->{sequence})) {
			my $latest_successful = $self->deployments->latest_successful;
			return $latest_successful if $latest_successful && $old_exodus->{sequence} == $latest_successful->{sequence};
		};

		my $deployment_time = Time::Piece->strptime($old_exodus->{dated}, EXODUS_TIME_FORMAT);
		my $deployment_ts = $deployment_time->strftime(EXODUS_TIME_FORMAT_SHORT);
		my $last_deployment_ts = $last_deployment->{timestamp};
		my $genesis_version = $old_exodus->{version}//'(unknown version)';
		my $reason = $old_exodus->{reason}//'Unknown reason';
		my $deployment_data = $self->_build_deployment_audit_data(
			'deploy', 'success', $sequence,
			$deployment_time->strftime(EXODUS_TIME_FORMAT),
			kit => {
				name => $old_exodus->{kit_name},
				version => $old_exodus->{kit_version},
				is_dev => $old_exodus->{kit_is_dev} ? JSON::PP::true : JSON::PP->false,
				features => $old_exodus->{features},
			},
			user => {
				shell => $old_exodus->{deployer},
				vault => 'unknown',
				git => 'unknown',
				concourse => 'unknown',
			},
			manifest => {
				storage => 'repository',
				type => $old_exodus->{manifest_type},
				sha1 => $old_exodus->{manifest_sha1},
			},
			reason => $reason,
			genesis_version => $genesis_version,
		);
		$self->vault->set_path(
			$self->exodus_base."/deployments/$deployment_ts",
			$deployment_data,
			flatten => 1
		);

		# Update exodus with the new sequence number
		$self->vault->set($self->exodus_base, "sequence", $sequence);
	}
	return $self->deployment_lookup('latest');
}

# }}}
=cut

# env - return the environment associated with this deployment manager
sub env {
	return $_[0]->{env};
}

### Private Instance Methods

# _base_deployment_content - generates base deployment audit content {{{
sub _base_deployment_content {
	my ($self, $action, $result) = @_;
	my $env = $self->{env};

	my $base = {
		action          => $action,
		result          => $result,
		genesis_version => $Genesis::VERSION,
		reason          => 'unspecified',
	};

	unless ($result eq 'assumed') { # TODO: Handles backfilling of assumed deployments and terminations
		$base->{kit} = {
			id            => $env->kit->id,
			name          => $env->kit->name,
			version       => $env->kit->version,
			is_dev        => $env->kit->is_dev ? JSON::PP::true : JSON::PP->false,
			features      => join(',', $env->params->{kit}{features}->@*),
		};

		my $user_data = parse_fixed_width_table({array_rows => 1},
			lines(run({stderr => '/dev/null'},'who', '-mH'))
		)->[1];
		my $user = $user_data->[0] // $ENV{USER};
		$user .= (" ".$user_data->[3]) if $user_data->[3];
		$base->{user} = {
			shell         => $user,
			repo          => scalar($env->top->kit_provider->remote->get_authorized_user), # FIXME: only works for git-based kit providers
			vault         => scalar($env->vault->user),
			concourse     => $ENV{CONCOURSE_USERNAME} || undef,
			bosh          => $ENV{BOSH_USERNAME} || $ENV{BOSH_USER} || $ENV{BOSH_CLIENT} || undef,
		};

		$base->{artifacts} = $self->_base_artifacts($action);

		if ($action eq 'deploy') {
			$base->{manifest} = {
				type => $env->manifest_provider->deployment->type,
				sha2 => digest_file_hex(
					$env->deployment_cache_path_lookup('manifest'), 'SHA-256'
				)
			}
		}
	};
	return $base;
}
# }}}

# _base_artifacts - return a hashref of artifacts based on the action {{{
sub _base_artifacts {
	my ($self, $action) = @_;
	my $env = $self->{env};
	# Return a hashref of artifacts based on the action
	if ($action eq 'deploy') {
		return {
			log      => $env->deployment_cache_path_lookup('deploy_log'),
			manifest => $env->deployment_cache_path_lookup('manifest'),
			unpruned => $env->deployment_cache_path_lookup('unpruned_manifest'),
			vars     => $env->deployment_cache_path_lookup('vars'),
			state    => $env->deployment_cache_path_lookup('state'),
			store    => $env->deployment_cache_path_lookup('store'),
			secrets  => [keys($env->manifest_provider->vault_paths(notify => 0)->%*)],
			# TODO: add the dev kit, the ops directory and the env and its ancestors.
		};
	} elsif ($action eq 'terminate') {
		return {
			log      => $env->deployment_cache_path_lookup('deploy_log'),
			state    => $env->deployment_cache_path_lookup('state'),
		};
	} else {
		bail("Invalid action: %s", $action);
	}
}
# }}}

### Private Package Functions

# _get_last_day_of_month - utility function to calculate the last day of a given month {{{
sub _get_last_day_of_month {
	my ($year, $month) = @_;
	# Create the first day of the next month
	my $next_month = ($month == 12)
		? Time::Piece->strptime(($year + 1) . "-01-01", "%Y-%m-%d")
		: Time::Piece->strptime($year . "-" . sprintf("%02d", $month + 1) . "-01", "%Y-%m-%d");
	return ($next_month - ONE_DAY)->day_of_month;
}
# }}}

# _parse_into_timestamp_cmp - parse a timestamp string into a comparable timestamp {{{
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
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
