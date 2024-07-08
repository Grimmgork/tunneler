use strict;
use lib ".";
use Worker;
use Dispatcher;
use Class::Struct;

struct PathNode => {
	parent => '$',
	name => '$',
	gophertype => '$',
	childs => '@',
	id => '$',
	host => '$'
};

struct Host => {
	name => '$',
	port => '$',
	root => '$',
	id => '$',
	unvisited => '@',
	busy => '$',
	heat => '$'
};

my $pointer = 0;
my @array;
push @array, create_host();
push @array, create_host();
push @array, create_host();
push @array, create_host();
push @array, create_host();

sub create_host {
	my $host = Host->new();
	$host->busy(1);
	return $host;
}

sub find_next_work {
	my $count = scalar(@array);
	while ($count) {
		$count--;
		my $host = $array[0];
		push @array, shift @array;
		next unless $host;
		next if $host->busy;
		return pop @{$_->unvisited};
	}
	return undef;
}

find_next_work();

exit;

sub work {
	my $worker = shift;
	sleep(1);
	print "hello from heavy work\n";
	$worker->yield(1, 2, 3);
	return 0;
}

sub on_init {
	my $dispatcher = shift;
	$dispatcher->start_work(13);
	print "init\n";
	return 0;
}

sub on_work_yield {
	my $dispatcher = shift;
	my $workid = shift;
	print "yield $workid @_\n";
	return 0;
}

sub on_work_success {
	my $dispatcher = shift;
	my $workid = shift;
	print "success work $workid\n";
	$dispatcher->start_work(13);
	return 0;
}

sub on_work_error {
	my $dispatcher = shift;
	my $workid = shift;
	print "error work $workid\n";
	return 0;
}

my $dispatcher = Dispatcher->new(1, \&work, 
	\&on_init, 
	\&on_work_yield, 
	\&on_work_success, 
	\&on_work_error
);
$dispatcher->loop();