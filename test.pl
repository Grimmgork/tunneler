use strict;
use lib ".";
use Worker;
use Dispatcher;

sub work {
	my $worker = shift;
	sleep(1);
	print "hello from heavy work\n";
	$worker->yield(1, 2 , 3);
	return 0;
}

sub on_init {
	my $dispatcher = shift;
	$dispatcher->start_work();
	print "init\n";
	return 0;
}

sub on_work_yield {
	print "yield @_\n";
	return 0;
}

sub on_work_success {
	my $dispatcher = shift;
	print "success work\n";
	$dispatcher->start_work();
	return 0;
}

sub on_work_error {
	print "error work\n";
	return 0;
}

my $dispatcher = Dispatcher->new(1, \&work, 
	\&on_init, 
	\&on_work_yield, 
	\&on_work_success, 
	\&on_work_error
);
$dispatcher->loop();