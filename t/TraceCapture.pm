package TraceCapture;
# Run code with a TRACE-level file log and hand back what reached it.
#
# The redaction tests need to see exactly what Genesis writes to a trace
# log, which is the file an operator's ~/.genesis/mylogs/last-trace would
# hold.  capture_trace() points a fresh logger at a temporary file, runs
# the code, and returns the file's contents along with anything printed
# to the terminal, so a test can assert that a made-up secret is absent.
use strict;
use warnings;

use File::Temp qw/tempdir/;
use Digest::SHA qw/sha1_hex/;

use base 'Exporter';
our @EXPORT = qw/capture_trace fake_secret/;

# fake_secret - a throwaway value no real credential could collide with
sub fake_secret {
	my ($label) = @_;
	return sprintf("fake-%s-%s", $label // 'secret', sha1_hex(rand().$$.time()));
}

# capture_trace - run $code with a TRACE file log; returns (log, stderr, stdout)
sub capture_trace(&;%) {
	my ($code, %opts) = @_;
	require Genesis::Log;
	my $dir  = tempdir(CLEANUP => 1);
	my $file = "$dir/trace.log";
	my ($stderr, $stdout) = ('', '');
	{
		no warnings 'once';
		local $Genesis::Log::Logger = undef;
		# Each capture starts with an empty credential registry, so a value
		# a test expects to be scrubbed is one this capture registered, not
		# one an earlier test left behind.
		local %Genesis::Log::SECRETS = ();
		local $Genesis::Log::SECRET_PATTERN = undef;
		local $ENV{GENESIS_TRACE} = $opts{terminal_trace} ? 'y' : undef;
		local $ENV{GENESIS_DEBUG} = undef;
		local $ENV{QUIET} = undef;
		my $logger = Genesis::Log->new;
		$logger->configure_log(level => ($opts{terminal_level} // 'INFO'));
		$logger->configure_log($file, level => 'TRACE');
		local *STDERR;
		local *STDOUT;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		open STDOUT, '>', \$stdout or die "cannot capture stdout: $!";
		binmode STDERR, ':utf8';
		binmode STDOUT, ':utf8';
		$code->($logger, $file);
	}
	my $log = '';
	if (-f $file) {
		open my $fh, '<:encoding(UTF-8)', $file or die "cannot read $file: $!";
		$log = do {local $/; <$fh>};
		close $fh;
	}
	return wantarray ? ($log, $stderr, $stdout, $file) : $log;
}

1;
