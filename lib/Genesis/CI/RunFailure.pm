package Genesis::CI::RunFailure;
# The two classes of failure that end a propagate run, under D82.  They differ
# in whether a retry can help.  A run-fatal failure is the writer's own, which
# nothing the caller could do differently would have fixed, and an unsurvivable
# failure is an error no environment survives that a retry may fix, the remote
# being unreachable as the case.  Both abort the run the same way, so both
# live here.
use strict;
use warnings;

use Genesis::Exit qw/TEMPFAIL/;

### Constructors {{{

# fatal - the writer could not produce what it was told to produce {{{
#
# It exits a bare 1, which is the one exit the design leaves unnamed, because
# a fatal system error is Genesis precedent a caller may already test for.
sub fatal {
	my ($class, %args) = @_;
	return bless({
		kind      => 'run-fatal',
		exit_code => 1,
		message   => $args{message}
			// 'the writer could not produce what it was told to produce',
		branch    => $args{branch},
		source    => $args{source},
		paths     => $args{paths} || [],
	}, $class);
}

# }}}
# unsurvivable - no environment survives it, but a retry may fix it {{{
sub unsurvivable {
	my ($class, %args) = @_;
	return bless({
		kind      => 'unsurvivable',
		exit_code => TEMPFAIL,
		message   => $args{message} // 'the run cannot continue',
		branch    => $args{branch},
		source    => $args{source},
		paths     => $args{paths} || [],
		remedy    => $args{remedy},
	}, $class);
}

# }}}
# }}}

### Accessors {{{

# kind - which of the two classes this failure is {{{
sub kind { $_[0]{kind} }

# }}}
# exit_code - the status the run exits with for this failure {{{
sub exit_code { $_[0]{exit_code} }

# }}}
# branch - the branch the failure happened on {{{
sub branch { $_[0]{branch} }

# }}}
# source - the commit the writer was delivering {{{
sub source { $_[0]{source} }

# }}}
# paths - the paths the failure names {{{
sub paths { @{$_[0]{paths}} }

# }}}
# remedy - the corrective step an unsurvivable failure carries {{{
sub remedy { $_[0]{remedy} }

# }}}
# }}}

### The report {{{

# report_line - the line the run's report carries, naming the difference {{{
#
# Composed once, because the report is where an operator learns what ended
# the run and a run over several environments has to say which one lost.
sub report_line {
	my ($self) = @_;
	my $line = $self->{message};
	$line .= sprintf(" on %s", $self->{branch}) if $self->{branch};
	$line .= sprintf(" against %s", $self->{source}) if $self->{source};
	$line .= sprintf(": %s", join(', ', @{$self->{paths}})) if @{$self->{paths}};
	$line .= sprintf(" (%s)", $self->{remedy}) if $self->{remedy};
	return $line;
}

# }}}
# abort_outcomes - what every environment records when a run ends early {{{
#
# Both classes abort the same way, so the words are the same for both.  An
# environment the run had already walked records that nothing of its was
# published, and one it never reached records that it was not attempted.
# Nothing is left out of the report, which is I8.
#
# A run that names no environment is one that died before it reached any, so
# every environment records that it was not attempted.  Walking the list as
# though the run had reached them all would tell an operator that a run which
# never started had published nothing for each of them in turn.
sub abort_outcomes {
	my ($envs, $failed) = @_;
	my $fields = abort_fields($envs, $failed);
	return {map {
		($_ => join(', ', grep {defined}
			$fields->{$_}{outcome}, $fields->{$_}{detail}))
	} keys %$fields};
}

# }}}
# abort_fields - the same answer as the record's two fields {{{
#
# Ruling 22 splits the record's outcome from its qualifier, so the bare enum
# word Genesis::CI::Report declares stands in outcome and the run's own
# annotation stands in outcome_detail, and the status a run exits with is
# decided by matching one whole word rather than by cutting a phrase apart.
# The phrase an operator reads is composed back from the two, so there is one
# place that decides and one that spells.
sub abort_fields {
	my ($envs, $failed) = @_;
	my %fields;
	my $reached = defined $failed ? 1 : 0;
	for my $env (@$envs) {
		$fields{$env} = $reached
			? {outcome => 'not published', detail => 'run aborted'}
			: {outcome => 'not attempted', detail => undef};
		$reached = 0 if defined $failed && $env eq $failed;
	}
	return \%fields;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
