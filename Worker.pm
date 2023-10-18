package Worker;

use strict;
use Time::HiRes qw(usleep);

sub new {
	my $class = shift;
	my $writer, my $reader;
	pipe($reader, $writer);
	$writer->autoflush(1);

	my $self = {
		id	  => shift,
		work   => shift,
		writer => $writer,
		reader => $reader
	};

	bless $self, $class;
	return $self;
}

sub done {
	my $self = shift;
	my $writer = $self->{writer};
	print $writer "e\n";
}

sub work {
	my $self = shift;
	my $payload = shift;
	
	my $writer = $self->{writer};
	print $writer "w$payload\n";
}

sub respond {
	my($self, $out, $type, $payload) = @_;
	print $out $self->{id} . "$type$payload\n";
}

sub fork {
	my $self = shift;
	my $out = shift;

	my $pid = fork(); # - fork
	unless($pid) { # child
		sleep(1);
		close $self->{writer};
		thread($self, $out);
		exit(0); # - fork end
	}
}

sub thread {
	my ($self, $out) = @_;

	my $id = $self->{id};
	print "## worker $id started!\n";
	respond($self, $out, "i"); # respond with "initialized"

	my $reader = $self->{reader};
	while(<$reader>) {
		
		chomp($_);
		next if $_ eq "";

		my ($cmd, $payload) = $_ =~ /([a-z])(.*)/;
		# end command
		if($cmd eq 'e') {
			last;
		}

		# start work command
		if($cmd eq 'w') {
			my $code;
			eval {
				$code = $self->{work}->($self, $payload);
			}; if($@) {
				$code = 99;
			}
			respond($self, $out, "e", $code);
		}
	}

	print "## worker $id shutdown!\n";
	respond($self, $out, "x", 0);

	close $self->{reader};
	close $self->{writer};
	close $out;
}

1;