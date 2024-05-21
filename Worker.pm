package Worker;

use strict;
use Time::HiRes qw(usleep);
use IO::Select;
use Socket;
use IO::Handle;
use IO::Select;

sub new {
	my $class = shift;
	socketpair(my $child, my $parent, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
	$child->autoflush(1);
	$parent->autoflush(1);

	my $self = {
		work   => shift,
		child => $child,
		parent => $parent,
		pid => undef
	};

	bless $self, $class;
	return $self;
}

sub has_response {
	my $self = shift;
	my $select = IO::Select->new();
	$select->add($self->{child});
	return $select->can_read(0);
}

sub read_response {
	my $self = shift;
	return read_array($self->{child});
}

sub start_work {
	my $self = shift;
	write_array($self->{child}, "w", @_);
}

sub dispose {
	my $self = shift;
	my $child = $self->{child};
	my $parent = $self->{parent};
	write_array($child, "e");
	
	my $pid = $self->{pid};
	if (defined $pid) {
		waitpid($pid, 0);
	}
	close $parent;
	close $child;
}

# used by the "work" to respond data
sub yield {
	my $self = shift;
	write_array($self->{parent}, "y", @_);
}

sub fork {
	my $self = shift;
	my $pid = fork;
	if ($pid == 0)
	{
		# child
		close $self->{child};
		print "## worker started!\n";
		thread($self);
		print "## worker shutdown!\n";
		close $self->{parent};
		exit(0); # - fork end
	}
	else
	{
		# parent
		$self->{pid} = $pid;
		close $self->{parent};
	}
}

sub thread {
	my $self = shift;
	my $parent = $self->{parent};
	my @command;
	while(@command = read_array($parent)) {
		my $type = shift @command;

		# end command
		if($type eq "e") {
			last;
		}

		# start work command
		if($type eq "w") {
			my $code;
			eval {
				$code = $self->{work}->($self, @command);
			}; if($@) {
				$code = 99; # exception occured
			}
			write_array($parent, "e", $code); # signal the end to parent
		}
	}
}

sub write_array {
	my $handle = shift;
	my $length = @_;
	write_raw($handle, "$length\n");
	foreach(@_) {
		my $arg_length = length $_;
		write_raw($handle, "$arg_length\n");
		write_raw($handle, $_);
	}
}

sub read_array {
	my $handle = shift;
	my @result;
	my $n_of_args = read_raw_line($handle);
	foreach(1..$n_of_args) {
		my $length = read_raw_line($handle);
		push @result, read_raw($handle, $length);
	}
	return @result;
}

sub read_raw_line {
	my $handle = shift;
	my $result = "";
	my $char = "";
	while($char ne "\n") {
		$char = read_raw($handle, 1);
		$result = $result . $char;
	}
	return $result;
}


sub write_raw {
	my $handle = shift;
	my $message = shift;
	my $message_length = length $message;
	my $written = 0;
	while($written < $message_length) { 
		$written += syswrite($handle, $message, $message_length, $written);
	}
}

sub read_raw {
	my $handle = shift;
	my $length = shift;
	my $message;
	my $read = 0;
	while($read < $length) {
		$read += sysread($handle, $message, $length, $read);
	}
	return $message;
}

1;