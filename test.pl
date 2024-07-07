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

sub methoda {
	return [rand(10), rand(10), rand(10), rand(10) ,rand(10), rand(10), rand(10), rand(10), rand(10), rand(10)];
}

sub methodb {
	return (rand(10), rand(10), rand(10), rand(10) ,rand(10), rand(10), rand(10), rand(10), rand(10), rand(10));
}


print "start a ...\n";
my $keka = 0;
my $starta = time;
foreach(1..10000000)
{
	my $result = methoda();
	foreach(@$result) {
		$keka += $_;
	}
}
print time - $starta, "\n";

print "start b ...\n";
my $kekb = 0;
my $startb = time;
foreach(1..10000000)
{
	my @result = methodb();
	foreach(@result) {
		$kekb += $_;
	}
}
print time - $startb, "\n";
print $keka, "\n";
print $kekb, "\n";
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