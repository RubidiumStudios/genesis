#!/usr/bin/env perl
# Proves T523's comparison: how the Genesis embedded in a repository is told
# apart from the one running (D189).  The two are the same where their bytes
# are; failing that, a packed build's version is read out of it.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use MIME::Base64 qw/encode_base64/;
use IO::Compress::Gzip qw/gzip/;

use Genesis::Top;

# A file shaped as ./pack leaves one: a script, the end marker, a checksum
# line, and the library as a gzipped stream in base64.  The stream here is
# the one line the version is read from.
sub packed {
	my ($line) = @_;
	gzip(\"package Genesis;\n$line\n1;\n" => \my $gz) or die 'gzip failed';
	return "#!/usr/bin/env perl\nprint qq(genesis)\n__END__\n0123abcd\n" . encode_base64($gz);
}

subtest 'a packed build says its version' => sub {
	plan tests => 4;

	is(Genesis::Top::packed_genesis_version(packed('$VERSION = "3.2.0";')), '3.2.0',
		'as pack brands it');
	is(Genesis::Top::packed_genesis_version(packed('$Genesis::VERSION = "2.8.0";')), '2.8.0',
		'and as earlier releases wrote it');
	is(Genesis::Top::packed_genesis_version("#!/bin/sh\nexit 0\n"), undef,
		'a file that is no packed build has none');
	is(Genesis::Top::packed_genesis_version(undef), undef, 'and neither has nothing');
};

subtest 'the embedded Genesis is judged against the one running' => sub {
	plan tests => 6;

	my $verdict = \&Genesis::Top::embedded_genesis_verdict;

	is($verdict->(undef, 'aaa', '3.2.0')->{is}, 'missing', 'none embedded is missing');

	is($verdict->({sha => 'aaa', content => 'anything'}, 'aaa', '3.2.0')->{is}, 'same',
		'the same bytes are the same, whatever they hold');

	my $other_build = $verdict->({sha => 'bbb', content => packed('$VERSION = "3.2.0";')}, 'aaa', '3.2.0');
	is($other_build->{is}, 'same-version', 'other bytes of the running version are another build of it');

	my $older = $verdict->({sha => 'bbb', content => packed('$VERSION = "3.1.4";')}, 'aaa', '3.2.0');
	is($older->{is}, 'differs', 'another version differs');
	is_deeply([@{$older}{qw/embedded running/}], ['3.1.4', '3.2.0'], 'and both versions are answered');

	is($verdict->({sha => 'bbb', content => "#!/bin/sh\nexit 0\n"}, 'aaa', '3.2.0')->{is}, 'differs',
		'and so does a file no version can be read from');
};

done_testing;
