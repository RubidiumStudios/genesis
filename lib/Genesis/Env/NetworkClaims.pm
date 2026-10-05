package Genesis::Env::NetworkClaims;

use strict;
use warnings;

use Genesis;
use IPv4;

# claims_flat - a network map as the vault stores it, so two of them compare by what they hold {{{
sub claims_flat {
	my ($map) = @_;
	my $flat = flatten({}, '', $map);
	# set_path stores no empty hash or array, so neither is a difference
	return {map {($_ => $flat->{$_} // '')} grep {!ref($flat->{$_})} keys %$flat};
}

# }}}
# claims_changes - how the claims of a network map differ from the stored record, by network and subnet {{{
sub claims_changes {
	my ($stored, $map) = @_;
	my $claims = sub {
		my ($record) = @_;
		my $subnets = ref($record) eq 'HASH' && ref($record->{subnets}) eq 'HASH' ? $record->{subnets} : {};
		my %found;
		for my $subnet (keys %$subnets) {
			my $held = ref($subnets->{$subnet}) eq 'HASH' ? $subnets->{$subnet}{claims} : undef;
			next unless ref($held) eq 'HASH';
			$found{$_}{$subnet} = $held->{$_} for keys %$held;
		}
		return \%found;
	};
	my ($old, $new) = ($claims->($stored), $claims->($map));
	# The addresses of one range that another does not hold.  A value that is
	# not a range of addresses is shown as it is.
	my $addresses = sub {
		my ($range, $without) = @_;
		return '' unless defined($range) && length($range);
		return $range unless defined($without) && length($without);
		my $left = eval {
			my %taken = map {("$_" => 1)} IPv4->new($without)->addresses;
			IPv4->range(grep {!$taken{$_}} map {"$_"} IPv4->new($range)->addresses)->range;
		};
		return defined($left) ? $left : $range;
	};

	my @changes;
	for my $network (sort keys %{{%$old, %$new}}) {
		for my $subnet (sort keys %{{%{$old->{$network} // {}}, %{$new->{$network} // {}}}}) {
			my ($was, $now) = ($old->{$network}{$subnet}, $new->{$network}{$subnet});
			next if ($was // '') eq ($now // '');
			my ($added, $removed) = ($addresses->($now, $was), $addresses->($was, $now));
			next unless length($added) || length($removed);
			push @changes, {network => $network, subnet => $subnet, added => $added, removed => $removed};
		}
	}
	return @changes;
}

# }}}
# claims_summary - tell the operator what a write of the network claims changes {{{
sub claims_summary {
	my ($path, $stored, $map, %opts) = @_;
	my @changes = claims_changes($stored, $map);
	unless (@changes) {
		# A deploy writes the record every time, so saying so each time is noise;
		# a command run to write the claims on purpose says what it found
		my $say = $opts{say_unchanged} ? \&info : \&debug;
		$say->("[[  - >>the network claims at #C{%s} keep the same addresses.", $path);
		return;
	}
	info("[[  - >>the network claims at #C{%s} change:", $path);
	for my $change (@changes) {
		info(
			"[[      >>#M{%s} (%s): %s", $change->{network}, $change->{subnet},
			join(', ',
				(length($change->{added})   ? "adds #G{$change->{added}}"       : ()),
				(length($change->{removed}) ? "removes #R{$change->{removed}}" : ())
			)
		);
	}
	return;
}

# }}}

1;
