package Genesis::CI::RunFailure;
# The two classes of failure that end a propagate run, under D82.  They differ
# in whether a retry can help.  A run-fatal failure is the writer's own, which
# nothing the caller could do differently would have fixed, and an unsurvivable
# failure is an error no environment survives that a retry may fix, the remote
# being unreachable as the case.  Both abort the run the same way, so both
# live here.
use strict;
use warnings;

use Exporter qw/import/;
use Genesis::Exit qw/TEMPFAIL/;

our @EXPORT_OK = qw/one_line/;

### The reason {{{

# one_line - the first substantive line of whatever a failure carried {{{
#
# Both the writer's own failures and the command's refusals print one line
# beside the branch or the environment they happened on, and a death out of
# run, or out of bail, is several decorated lines of which the first
# substantive one says what went wrong.  It lives here because both callers
# are about the messages this class carries, and two subs doing this job in
# two files is how the two came to strip different things.
#
# A caller printing a line of its own is given the sentence whole, because a
# reason cut at a column loses the end of the sentence that names the file.
# A caller printing into a column says so through width, and gets the reason
# cut there with the cut marked, because a long reason inside a table wraps
# the table apart and the row below it reads as the reason's continuation.
# The status table is the one caller with a width to give.
sub one_line {
	my ($err, %opts) = @_;
	return 'unknown reason' unless defined($err) && length("$err");

	my $text = "$err";
	$text =~ s/\e\[[0-9;]*m//g;
	$text =~ s/\[FATAL\]\s*//g;
	$text =~ s/Environment\s+\S+\s+could not be loaded:\s*//g;
	$text =~ s/Please fix the above errors and try again\.\s*//g;

	for my $line (split /\n/, $text) {
		$line =~ s/^\s*-\s+//;
		$line =~ s/^\s+|\s+$//g;
		next unless length $line;
		next if $line =~ /^at \S+ line \d+/;
		return _fit($line, $opts{width});
	}
	return 'unknown reason';
}

# }}}
# _fit - one reason at the width a caller asked for, with the cut marked {{{
#
# The mark is what tells a reader that the sentence goes on, so a trim that
# ended at the width and said nothing would have them act on half a path.
sub _fit {
	my ($line, $width) = @_;

	return $line unless defined $width && $width > 0;
	return $line unless length($line) > $width;
	return substr($line, 0, $width) . '...';
}

# }}}
# }}}

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
