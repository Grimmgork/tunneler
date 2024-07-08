use strict;
use Class::Struct;
use IO::Socket::INET;

use lib ".";
use Data;
use Dispatcher;

# ~ CONFIG:
use constant CONFIG => {
	ping			=> "8.8.8.8",
	file_db			=> "gopherspace.db",
	file_stat		=> "status.txt",
	max_depth		=> 4,
	no_workers		=> 4,
	no_hosts		=> 5
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

struct PathNode => {
	parent => '$',
	name => '$',
	gophertype => '$',
	childs => '@',
	id => '$',
	host => '$'
};

print "INDEXING ...\n";
my $DATA = Data->new();
$DATA->init(CONFIG->{file_db});
print "DONE!\n";

# inject initial host
if (scalar(@ARGV) > 0) {
	$DATA->try_register_host(shift(@ARGV), shift(@ARGV) || 70);
}

# allocate array of hosts
my @hosts;
$hosts[CONFIG->{no_hosts}-1] = undef;

sub on_init {
	my ($dispatcher) = @_;

	my $end = state_has_changed($dispatcher);
	return $end;
}

sub find_next_work {
	my $count = scalar(@hosts);
	while ($count) {
		$count--;
		my $host = $hosts[0];
		push @hosts, shift @hosts;
		next unless $host;
		next if $host->busy;
		return pop @{$host->unvisited};
	}
	return undef;
}

sub state_has_changed {
	my $dispatcher = shift;
	# remove empty non busy hosts
	foreach (0..$#hosts) {
		my $host = $hosts[$_];
		next unless $host;
		next if $host->busy;
		unless (scalar(@{$host->unvisited})) # if there is nothing more to explore
		{
			$DATA->set_host_status($host->id, 1); # mark host as done
			$hosts[$_] = undef; # remove host
		}
	}

	# try load unique unvisited hosts into empty slots (fifo)
	my @blacklist;
	foreach (@hosts) {
		push(@blacklist, $_->id) if $_;
	}
	my @ids = $DATA->get_unvisited_hostids(scalar(@hosts) - scalar(@blacklist), @blacklist);
	foreach (0..$#hosts) {
		unless ($hosts[$_]) {
			my $id = shift @ids;
			last unless $id;
			$hosts[$_] = load_host_from_database($id);
		}
	}

	# if there are no hosts in the list, end
	return 1 unless grep { defined $_ } @hosts;

	# while work is available
	while ($dispatcher->free_workers()) {
		my $node = find_next_work();
		last unless $node; # if there is no work to be found
		$dispatcher->start_work($node, $node->host->name, $node->host->port, get_path_from_node($node));
		$node->host->busy(1);
	}

	return 0;
}

sub on_work_yield {
	my $dispatcher = shift;
	my $context = shift;
	my $type = shift;

	if ($type eq "r") {
		digest_ref($context->host, shift, shift);
	}
	elsif ($type eq "p") {
		digest_path($context->host, @_);
	}
	
	my $end = state_has_changed($dispatcher);
	return $end;
}

sub on_work_success {
	my ($dispatcher, $context) = @_;

	$DATA->set_endpoint_status($context->id, 1);
	$context->host->busy(0);

	my $end = state_has_changed($dispatcher);
	return $end;
}

sub on_work_error {
	my ($dispatcher, $context, $error) = @_;

	print "ERROR: host:", $context->host->name, " nodeid:", $context->id, " code:$error\n";

	$DATA->set_endpoint_status($context->id, 2);
	$context->host->busy(0);
	
	my $end = state_has_changed($dispatcher);
	return $end;
}

my $dispatcher = Dispatcher->new(CONFIG->{no_workers}, 
	\&work, 
	\&on_init, 
	\&on_work_yield, 
	\&on_work_success, 
	\&on_work_error
);
$dispatcher->loop();

$DATA->disconnect();
exit 0;

sub work {
	my ($worker, $hostname, $port, $path) = @_;
	print "FETCH: $hostname:$port $path\n";

	# make request
	my $socket = IO::Socket::INET->new(
    	PeerHost => $hostname,
    	PeerPort => $port,
    	Proto => 'tcp',
		Timeout => 5
	);

	return 1 unless defined $socket;

	$socket->send("$path\n");
	
	my $selector = IO::Select->new();
	$selector->add($socket);
	unless (defined $selector->can_read(5)) {
		close($socket);
		return 2;
	}

	foreach (<$socket>) {
		last if $_ eq "."; # end of gopher page

		my ($rowtype, $rowpath, $rowhost, $rowport) = $_ =~ /^([^i3\s])[^\t]*\t([^\t]*)\t([^\t]*)\t(\d+)/;
		next unless defined $rowtype;

		# try parse full url reference
		if (my ($url) = $rowpath =~ m/UR[LI]:(.+)/gi) {
			my ($protocol, $host, $port) = $url =~ m/^([a-z0-9]*):\/\/([a-zA-Z0-9.]+)(?::(\d+))?(?:\/.*)?$/gi;
			$worker->yield("r", $host, $port || 70) if $protocol eq "gopher" and $host ne $hostname;
			next;
		}

		$rowpath = clean_path($rowpath);
		$rowhost = trim(lc($rowhost)); # trim and lowercase

		# skip unwanted host names like ftp.* and *.onion
		next if $rowhost =~ /[^a-z0-9-\.]|ftp\.|\.onion/i;
		unless ($rowhost) {
			$rowhost = $hostname;
			$rowport = $port unless $rowport;
		}

		if (($rowhost eq $hostname) && ($rowport eq $port)) { 
			# endpoint of current host
			$worker->yield("p", $rowtype, split(/\//, $rowpath));
		}
		else {
			# reference to foreign host
			$worker->yield("r", $rowhost, $rowport);
		}
	}

	# close tcp socket
	close($socket);
	return 0;
}

# a reference to local path on the same host
sub digest_path {
	my ($host, $gophertype, @segments) = @_;

	my ($endpoint, @added) = host_add_endpoint($host, $gophertype, @segments);
	foreach (@added) {
		if ($_->gophertype eq "1" and scalar(@segments) <= CONFIG->{max_depth}) { # if its a gopherpage, and the path is not too deep, check it out later
			push(@{$host->unvisited}, $_);
		}
		$_->id($DATA->add_endpoint($host->id, $gophertype, get_path_from_node($_), 0));
		print "~ PATH: ", $host->id, " $gophertype @segments\n";
	}
}

# a reference to a foreign host, potentially unknown
sub digest_ref {
	my ($host, $hostname, $port) = @_;
	# TODO remove when ready
	unless ($DATA->get_host_id($hostname, $port)) {
		print "* DISCOVERED $hostname:$port\n";
	}
	my $id = $DATA->try_register_host($hostname, $port);
	$DATA->increment_reference($host->id, $id);
}

sub host_add_endpoint {
	my ($host, $type, @segments) = @_;
	my $current = $host->root;
	my @newendpoints = ();

	if (not defined $current) {
		$current = PathNode->new();
		$current->name("");
		$current->gophertype("1");
		$current->host($host);
		$host->root($current);
		push @newendpoints, $current;
	}

	# assume there is always a empty root segment
	shift(@segments);
	
	foreach my $segment (@segments) {
		# search children
		my $found = undef;
		foreach (@{$current->childs}) {
			if ($_->name eq $segment) {
				$found = $_;
				last;
			}
		}
		unless (defined $found) {
			# add new segment-node
			$found = PathNode->new();
			$found->name($segment);
			$found->parent($current);
			$found->gophertype("1");
			$found->host($host);

			push @{$current->childs}, $found;
			push @newendpoints, $found;
		}
		$current = $found;
	}
	# set the last segments type and id ... O~O
	$current->gophertype($type);
	return ($current, @newendpoints);
}

sub get_path_from_node {
	my $node = $_[0];
	unless (defined $node->parent) {
		return $node->name;
	}
	my $name = $node->name;
	my $path = get_path_from_node($node->parent);
	return "$path/$name";
}

sub load_host_from_database {
	my $hostid = shift;
	my ($hostname, $port) = $DATA->get_host_from_id($hostid);

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);
	$host->id($hostid);

	$host->root(undef);

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = $DATA->get_endpoints_from_host($host->id);
	foreach (@$rows) {
		my @segments = split(/\//, @$_[3]);
		my ($endpoint, @added) = host_add_endpoint($host, @$_[2], @segments);
		
		# if its already in the cache (no endpoints have been added to cache)
		if (scalar(@added) == 0) { 
			# <STDIN>;
			# print "duplicate endpoint in database:\n";
			# print @$_[3], "\n";
			next;
		}

		# set created endpoints id
		$endpoint->id(@$_[0]);
		if (@$_[4] == 0 and @$_[2] == 1 and scalar(@segments) <= CONFIG->{max_depth}) { # if unvisited and is a gopher page and path os not too deep
			push @{$host->unvisited}, $endpoint; # add to unvisited
		}
	}

	# check if the root is already in, if not add it. 
	my ($root, @added) = host_add_endpoint($host, "1", split(/\//, ""));
	if (scalar(@added) > 0) {
		push @{$host->unvisited}, $root;
	}

	return $host;
}

sub trim {
	my($str) = @_;
	$str =~ s/^\s+|\s+$//g;
	return $str;
}

sub clean_path {
	my ($path) = @_;
	$path =~ s/\\/\//g; #replace \ with /
	$path =~ s/^[\s\/]+|[\/\s]+$//g; #trim right / and left + right withespaces
	if($path eq ""){
		return "";
	}
	return "/$path";
}
