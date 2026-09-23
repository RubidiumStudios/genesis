package Harness::Profile;
# Opt-in timing for the suite: where a test file's time goes.
#
# Loaded through PERL5OPT, so a genesis child a test spawns loads it too, and
# active only while GENESIS_TEST_PROFILE names a log.  It wraps Genesis::run,
# the one door every spawn goes through, before any package imports it, and
# logs each command's program and interval.  At exit it logs the process's own
# CPU.  The harness runs genesis through Genesis::run as well, so one log holds
# the runs, the harness's own spawns and the product's.
#
# Only a test file (a name ending in .t) and bin/genesis are profiled.  Every
# other perl that inherits PERL5OPT, prove and the harness's curl double among
# them, loads this and does nothing, since loading Genesis there would cost
# more than the call it measures.
use strict;
use warnings;

use Time::HiRes ();

my $LOG = $ENV{GENESIS_TEST_PROFILE};
my $START = Time::HiRes::time();
my $PROFILED = $LOG && $0 =~ m{(?:\.t|/genesis)$};

# Each line names the test file its process descends from, so a log written
# by a whole run can be read one file at a time.
$ENV{HARNESS_PROFILE_ROOT} //= "$$:$0" if $PROFILED;
my $ROOT = $ENV{HARNESS_PROFILE_ROOT} // '';

sub _log {
	my (@fields) = @_;
	open my $fh, '>>', $LOG or return;
	print $fh join("\t", @fields), "\n";
	close $fh;
}

# _program - the program a Genesis::run call names, for the log {{{
#
# The first argument that is not the options hash is either a program or a
# shell string, so its first word is the program either way.
sub _program {
	my ($cmd) = grep {!ref($_)} @_;
	my ($word) = ($cmd // '') =~ m{^\s*(\S+)};
	return ($word // '') =~ s{.*/}{}r;
}
# }}}

# _wrap_run - put the timing around Genesis::run {{{
sub _wrap_run {
	my $run = \&Genesis::run;
	no warnings 'redefine';
	*Genesis::run = sub {
		my $start = Time::HiRes::time();
		my $want  = wantarray;
		my @out   = $want ? $run->(@_)
		          : defined($want) ? scalar($run->(@_))
		          : do {$run->(@_); ()};
		_log('run', $ROOT, $$, $start, Time::HiRes::time(), _program(@_));
		return $want ? @out : $out[0];
	};
}
# }}}

# Genesis is wrapped at the moment the program first requires it, not here.
# Loading it from PERL5OPT would load it before the test's own helper has set
# up the environment Genesis reads as it loads, and the run would differ from
# an unprofiled one.  An @INC hook would not do either, since `use lib` and
# bin/genesis put the library ahead of it.  Overriding require catches the
# load wherever it comes from, and wraps run after Genesis.pm has loaded and
# before `use Genesis` imports it.
if ($PROFILED) {
	my $wrapped = 0;
	*CORE::GLOBAL::require = sub {
		my ($file) = @_;
		my $loaded = CORE::require($file);
		_wrap_run() if $file eq 'Genesis.pm' && !$wrapped++;
		return $loaded;
	};
}

END {
	if ($PROFILED) {
		my ($user, $sys, $cuser, $csys) = times;
		_log('proc', $ROOT, $$, $0, $START, Time::HiRes::time(),
			$user, $sys, $cuser, $csys);
	}
}

1;
