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
use IO::Handle;
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
	my ($ok, $error);
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
		# Capture file descriptors 1 and 2 themselves, so what a child
		# process writes is captured along with Perl's own output.
		my %utf8 = map {
			my $fh = $_->[1];
			($_->[0] => scalar(grep {/utf8/} PerlIO::get_layers($fh)))
		} (['out', \*STDOUT], ['err', \*STDERR]);
		open my $saved_out, '>&', \*STDOUT or die "cannot save stdout: $!";
		open my $saved_err, '>&', \*STDERR or die "cannot save stderr: $!";
		open STDOUT, '>', "$dir/stdout" or die "cannot capture stdout: $!";
		open STDERR, '>', "$dir/stderr" or die "cannot capture stderr: $!";
		binmode STDERR, ':utf8';
		binmode STDOUT, ':utf8';
		STDOUT->autoflush(1);
		STDERR->autoflush(1);
		$ok = eval { $code->($logger, $file); 1 };
		$error = $@;
		open STDOUT, '>&', $saved_out or die "cannot restore stdout: $!";
		open STDERR, '>&', $saved_err or die "cannot restore stderr: $!";
		binmode STDOUT, ':utf8' if $utf8{out};
		binmode STDERR, ':utf8' if $utf8{err};
		$stdout = _slurp("$dir/stdout");
		$stderr = _slurp("$dir/stderr");
	}
	die $error unless $ok;
	my $log = _slurp($file);
	return wantarray ? ($log, $stderr, $stdout, $file) : $log;
}

sub _slurp {
	my ($file) = @_;
	return '' unless -f $file;
	open my $fh, '<:encoding(UTF-8)', $file or die "cannot read $file: $!";
	my $content = do {local $/; <$fh>};
	close $fh;
	return $content // '';
}

1;
