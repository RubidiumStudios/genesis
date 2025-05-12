package Genesis::Hook::Presenter;
use strict;
use warnings;

# This is not a hook module, but a support module for hook modules.  It is
# responsible for providing a Presenter object that can be used to render
# the output of a hook module in a way that is suitable for the Genesis
# CLI to present to the user.  This way the hook doesn't have to worry about
# how to format its output, it just needs to provide the data.

use Genesis::Term;
use Genesis::UI;
use Time::HiRes;

# For now, this will only return a CLI presenter, but the `new` method could
# be extended to take a type argument to return a different presenter type
# in the future (ie web, json, etc)
sub new {
	my ($class,$hook) = @_;
	return bless({hook => $hook}, $class);
}

sub start {
	my ($self, $title) = @_;
	$self->{start_time} = Time::HiRes::time();
	$self->{hook}->notify($title);
}

sub start_itemized_list {
	my ($self, $title,$count) = @_;
	$self->{item_max} = $count;
	$self->{item_count} = 0;
	$self->{previous_lines} = 0;
	$self->{idx_width} = length($count);
	$self->{start_itemized_time} = Time::HiRes::time();
	info("[[  - >>$title",$count);
}

sub add_item {
	my ($self, $item, $overwritable) = @_;
	$self->{item_count}++;
	my $msg = wrap(sprintf(
		"[[    [%*d/%*d] >>%s",
		$self->{idx_width}, $self->{item_count}, $self->{idx_width}, $self->{item_max}, $item
	), terminal_width);
	print STDERR "\r\e[A\e[2K" for (1..$self->{previous_lines});
	info $msg;
	$self->{previous_lines} = $overwritable ? scalar(lines($msg)) : 0;
}	

sub start_item	{
}
sub complete_item {

}

sub complete_itemized_list {

}

sub notify {
	my ($self, $message) = @_;
}

sub summary {
	my ($self, $message) = @_;
	
}
