package Genesis::CI::Status;
# The pipeline-status read model of D91.  One canonical record for the
# deployment root the command runs in, computed from the walk the propagate
# run uses, rendered either as the indented tree or as the JSON --json emits.
# This module writes nothing.
use strict;
use warnings;

use Exporter qw/import/;
use JSON::PP ();

use Genesis;
use Genesis::Term qw/csprintf/;
use Genesis::CI::Walk ();
use Genesis::CI::Preflight ();
# Genesis::CI::Report owns every word an operator reads about an outcome, so
# the phrase the never-applied reading carries is read from the constant
# rather than spelled a second time here.
use Genesis::CI::Report qw/AWAITING_APPLY/;
use Service::Git;

our @EXPORT_OK = qw/status_records render_tree render_json/;

# The word every cell resting on a refresh carries where the operator asked
# for none, which Refresh and divergence owns and which the marking of the
# stale report writes onto the record.
use constant UNVERIFIABLE => 'unverifiable';

# The five classes of D91, each mapped to markup Genesis::Term already has, so
# the renderer emits no escape sequence of its own.
our %CLASS_MARKUP = (
	settled   => 'G',
	in_flight => 'Y',
	on_ice    => 'B',
	wrong     => 'R',
	inert     => 'K',
);

our %CLASS_GLYPH = (
	settled   => '+',
	in_flight => '!',
	on_ice    => 'O',
	wrong     => '-',
	inert     => '*',
);

# Worst first, so the row's glyph and name take the class an operator should
# look at before reading a phrase.
our @CLASS_ORDER = qw/wrong on_ice in_flight settled inert/;

# status_records - the canonical record for one deployment root {{{
#
# D91 fixes the record, and a command runs in one deployment root, so there is
# one record and the caller renders it.  The walk decides the routing and the
# certification, and the command renders what it hands back.
sub status_records {
	my ($top, %opts) = @_;
	my $git     = $opts{git} // Service::Git->new('.');
	my $refresh = exists $opts{refresh} ? $opts{refresh} : 1;

	my $refreshed = $refresh
		? $top->fetch_pipeline_envs($git, command => 'pipeline-status')
		: undef;

	# The status reports every state and resolves none, so a diverged control
	# is a line in the report rather than a refusal, and the one answer that
	# leaves the command nothing to read is still refused.
	my $control = Genesis::CI::Preflight::require_control($top, $git,
		refreshed     => $refreshed,
		command       => 'pipeline-status',
		unverifiable  => $refresh ? 0 : 1,
		on_divergence => 'report');

	# The one event this command has to account for, said here rather than by
	# the caller, because it goes to standard error and the caller's one
	# stream is the record itself.  The refresh created the local control ref
	# from the remote, which moved a ref the operator did not, and this line
	# is the only account of it they get.
	#
	# The stage's own event lines below are not said, because it moves no
	# branch for this command and a line reading "fast-forwarded" over a
	# branch that stands where it stood would be an account of a write nobody
	# made.  What those branches are is in the record's divergence cell.
	info("  #Gi{%s}", $_) for @{$control->{events}};

	# The stage is asked read-only, because this command reports and writes
	# nothing.  A branch the stage would have reset or fast-forwarded keeps
	# its own ref and carries the ref a real run would have moved it to,
	# which is the ref this report should be reading, and no caveat about a
	# preview is said, because nobody is about to make a run.
	my $initial = Genesis::CI::Preflight::initial_state($top, $git,
		envs      => [$top->pipeline_env_names],
		command   => 'pipeline-status',
		refreshed => $refreshed // 0,
		control   => $control,
		read_only => 1);

	return Genesis::CI::Walk::plan($top,
		git       => $git,
		branches  => $initial->{branches},
		scope     => $opts{scope},
		refreshed => $refresh ? 1 : 0,
	);
}

# }}}
# render_json - the record itself, in canonical key order {{{
#
# One object, because a command runs in one deployment root and the record is
# that root's.  A repository with a second root is read by running the command
# in it, which is how every other pipeline command reads one.
sub render_json {
	my ($record) = @_;
	return JSON::PP->new->canonical->pretty->encode(_jsonable($record));
}

# }}}
# _jsonable - the record with every object in it written out as its text {{{
#
# A deployment's timestamp reaches the record as a Time::Piece, because that
# is what the exodus reader answers with, and an encoder handed an object of
# any kind raises rather than guessing at one.  So each object is written as
# the text it prints as, which for that one is the date an operator would read
# anyway.  The record itself is left alone, since a caller may still be
# holding it.
sub _jsonable {
	my ($value) = @_;

	return $value unless ref $value;
	return [map {_jsonable($_)} @$value] if ref $value eq 'ARRAY';
	return {map {($_ => _jsonable($value->{$_}))} keys %$value}
		if ref $value eq 'HASH';

	# The encoder writes its own booleans back as true and false, so they are
	# the one blessed thing that goes through untouched.
	return $value if ref($value) eq 'JSON::PP::Boolean';
	return "$value";
}

# }}}
# render_tree - the root's environments as an indented tree in DAG order {{{
#
# The rendering is D91's constraint and not a suggestion, so we render the
# tree, the branch and deploy columns side by side, and one composed phrase
# per row.  The header names the pipeline by the label the configuration gives
# it, and by the deployment type where a repository names no label.
sub render_tree {
	my ($record, %opts) = @_;
	my @out;

	push @out, csprintf("\n#G{Pipeline}: #C{%s}  #Yi{provider}: %s  #Yi{control}: #C{%s}#Yi{\@}#C{%s}",
		$record->{pipeline} // $record->{type}, $record->{provider},
		$record->{control}{branch}, _short($record->{control}{commit}));
	push @out, '';

	my $width = 0;
	for my $row (@{$record->{environments}}) {
		my $w = ($row->{depth} * 2) + length($row->{env});
		$width = $w if $w > $width;
	}

	push @out, csprintf("  %s  #u{%-7s}  #u{%-7s}  #u{%s}",
		' ' x $width, 'branch', 'deploy', 'status');

	for my $row (@{$record->{environments}}) {
		my @phrase = compose_phrase($row, stale => $opts{stale});
		my $class  = worst_class(@phrase);
		my $name   = sprintf("%s%s%s",
			'  ' x $row->{depth}, $row->{env},
			' ' x ($width - ($row->{depth} * 2) - length($row->{env})));

		push @out, csprintf("  #%s{%s}  %-7s  %-7s  #%s\@{%s}%s",
			$CLASS_MARKUP{$class}, $name,
			_short($row->{merged}) // '-',
			_short($row->{deployed} ? $row->{deployed}{control_commit} : undef) // '-',
			$CLASS_MARKUP{$class}, $CLASS_GLYPH{$class},
			join('; ', map { csprintf("#%s{%s}", $CLASS_MARKUP{$_->[0]}, $_->[1]) } @phrase));
	}

	push @out, '';
	return join("\n", @out)."\n";
}

# }}}
# compose_phrase - the components in D91's fixed order {{{
#
# The order is the certification word, the routing summary, the snapshot flag,
# the pull request, the hold, and [manual].  Each component keeps its own
# class, and detail sits in square brackets after the word it qualifies.
sub compose_phrase {
	my ($row, %opts) = @_;
	return ([wrong => sprintf('load error: %s', $row->{error})]) if $row->{error};

	my %word = (
		'deployed'       => [settled   => 'deployed'],
		'pending-deploy' => [in_flight => 'awaiting deployment'],
		'unseeded'       => [settled   => 'unseeded'],
		'not-propagated' => [inert     => sprintf('not propagated, %s', AWAITING_APPLY)],
	);

	my @phrase = ($word{$row->{reading}} || [wrong => 'unknown reading']);
	my @pending = @{$row->{pending} || []};
	push @phrase, [in_flight => sprintf('%d pending', scalar @pending)]
		if @pending;
	push @phrase, [inert => '[manual]'] if $row->{manual};
	return @phrase;
}

# }}}
# worst_class - the class the row's glyph and name take {{{
sub worst_class {
	my (@phrase) = @_;
	my %present = map { $_->[0] => 1 } @phrase;
	for my $class (@CLASS_ORDER) {
		return $class if $present{$class};
	}
	return 'inert';
}

# }}}
# _short - the seven characters every column of this report abbreviates to {{{
#
# Genesis::CI::Report abbreviates to the same seven wherever it names a
# control commit, in hold_reason and in held_qualifier alike, so the run's
# report and this one print one sha at one width.
sub _short { my ($sha) = @_; return defined($sha) ? substr($sha, 0, 7) : undef }

# }}}
1;
