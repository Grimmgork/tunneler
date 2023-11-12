use lib ".";
use Queue;

use strict;

my $q = Queue->new();

my @items;
foreach(1..5){
	push @items, $_;
}

my $pid = fork();
$q->enqueue(@items);
print "$pid done!\n";
exit 0;