package Genesis::CI::Publish;
# The run's third stage.  The walk decides what is due and the delivery writes
# it onto the deployment branches in L, and everything here is about getting
# what L now holds onto R and saying, per environment, what the remote made of
# it.
#
# One push per branch, because D83 has a rejection on one branch cost one
# environment one run and nothing else.  No push's result withholds another's,
# which is the third stage of D96, and each result is that branch's outcome
# rather than a warning printed beside a success.
use strict;
use warnings;

use Exporter qw/import/;
use Genesis qw/info warning/;

our @EXPORT_OK = qw/publish_run/;

### The stage {{{

# publish_run - push every branch the run committed to, one at a time {{{
#
# A branch the remote refuses records the rejection as that environment's one
# outcome and goes straight back to where T has it, so the run ends with no
# local commit nobody else can see, and every other branch is published
# regardless of where the refusal fell.
#
# The bare enum word goes into outcome and everything qualifying it into
# outcome_detail, because the run's status and the report both match the whole
# of that field against the seven words I8 fixes.
#
# Returns { published => \@branches, rejected => \@branches, declined => 0,
# results => \@results }.
sub publish_run {
	my (%args) = @_;
	my $git     = $args{git};
	my $session = $args{session};
	my $remote  = $args{remote} || ($git ? $git->default_remote : undef);
	my $records = $args{records} || [];
	my @specs   = @{$args{specs} || []};

	my $result = {
		published => [], rejected => [], declined => 0, results => [],
	};
	return $result unless @specs && $remote;

	info "\n#G{Publishing} to #C{%s}...", $remote;

	# A death out of the push itself is the whole command failing rather than
	# one ref being turned down, and D82 answers it with the same abort a
	# remote that answered nothing earns, so it is caught here and handed to
	# the caller's own classifier with everything else.
	my $pushes = eval {$git->push(remote => $remote, refs => \@specs)};
	my $died   = $@;
	$pushes ||= [];
	$result->{results} = $pushes;

	# D82's unsurvivable remote.  A push where not one ref landed is the
	# remote being gone rather than any branch's own quarrel with it, so
	# nothing below runs: no environment is given an outcome it would have
	# to take back, and the run as a whole ends instead.  The classifier
	# that turns git's words into a remedy belongs beside the run, so the
	# caller raises it and this stage only says which reason to raise it on.
	unless (grep {$_->{ok}} @$pushes) {
		my $reason = $died;
		# The first ref that said anything, since the classifier reads one
		# line.
		$reason = (grep {length} map {$_->{reason}} @$pushes)[0]
			unless defined $reason && length "$reason";
		$args{unsurvivable}->($reason) if $args{unsurvivable};
		return $result;
	}

	for my $pushed (@$pushes) {
		my $spec = _spec_for(\@specs, $pushed->{branch});
		my $rec  = _record_for($records, $spec->{env});

		if ($pushed->{ok}) {
			push @{$result->{published}}, $pushed->{branch};
			info "  #G{%s}: published", $pushed->{branch};
			_mark_delivered($rec);
			next;
		}

		# The ref in the outcome is the one git named in its porcelain line,
		# and not one composed here out of the branch we asked for.
		my $moved = $pushed->{ref} // $pushed->{branch};
		$moved =~ s{^refs/heads/}{};

		if ($rec) {
			$rec->{outcome}        = 'publish rejected';
			$rec->{outcome_detail} = sprintf('%s moved on R', $moved);
		}

		# At once, rather than at the end of the run, because everything
		# after this point can still fail and a branch put back only on the
		# way out is a branch left standing wherever the run stopped.
		$session->reset_branch($pushed->{branch})
			if $session && ($spec->{kind} // '') ne 'control';

		push @{$result->{rejected}}, $pushed->{branch};
		warning("  #R{%s}: publish rejected, %s moved on R (%s)",
			$pushed->{branch}, $moved,
			length($pushed->{reason} // '') ? $pushed->{reason}
			                                : 'refused by the remote');
	}

	return $result;
}

# }}}
# }}}

### INTERNAL {{{

# _spec_for - the ref spec a push result belongs to {{{
sub _spec_for {
	my ($specs, $branch) = @_;
	for my $spec (@$specs) {
		return $spec if $spec->{branch} eq $branch;
	}
	return {};
}

# }}}
# _record_for - the walk's record for an environment {{{
sub _record_for {
	my ($records, $env) = @_;
	return undef unless defined $env;
	for my $rec (@$records) {
		return $rec if ($rec->{env} // '') eq $env;
	}
	return undef;
}

# }}}
# _mark_delivered - the commit axis of I8, for an environment that published {{{
#
# The report's per-commit word defaults to delivered, and the publish is what
# the enum names as the writer of it, so the word is written here for every
# commit an environment actually got onto R.  A rejected environment's commits
# are left null, because they are delivered in no sense the word carries.
sub _mark_delivered {
	my ($rec) = @_;
	return unless $rec;
	$_->{outcome} = 'delivered' for @{$rec->{pending} || []};
	return;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
