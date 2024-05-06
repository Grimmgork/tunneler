package Dispatcher;

use Worker;
use strict;

sub new {
	my $class = shift;
	my $number_of_workers = shift;
	my $self = {
		work => shift,
		on_init => shift,
		on_work_yield => shift,
		on_work_success => shift,
		on_work_error => shift,
		workers => (),
		free_workers => () # list of worker indexes
	};
	bless $self, $class;
	return $self;
}

sub loop {
	my $self = shift;
	
}

sub free_workers {

}

sub start_work {
	
}

sub done {

}

1;