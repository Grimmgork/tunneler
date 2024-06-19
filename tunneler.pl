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
	max_depth		=> 10,
	no_workers		=> 5,
	no_hosts		=> 5
};

struct Host => {
	name => '$',
	port => '$',
	root => '$',
	dbid => '$',
	unvisited => '@'
};

struct PathNode => {
	parent => '$',
	name => '$',
	gophertype => '$',
	childs => '@',
	dbid => '$'
};

print "INDEXING ...\n";
my $DATA = Data->new();
$DATA->init(CONFIG->{file_db});
print "DONE!\n";

# inject initial host
my $initial = shift @ARGV;
if ($initial) {
	my ($host, $port) = split_host_port($initial);
	$port = 70 unless defined $port;
	$DATA->try_register_host($host, $port);
}

my @hosts = ();
sub on_init {
	my $dispatcher = shift;

	# load hosts
	while (scalar(@hosts) < CONFIG->{no_hosts})
	{
		my @blacklist = map { $_->dbid } @hosts;
		my @ids = $DATA->get_unvisited_hostids(1, @blacklist);
		my $id = shift @ids;
		last unless defined $id; # done, no more hosts to load in the database
		my $host = load_host_from_database($id);
		push @hosts, $host;
	}

	unless (scalar(@hosts)) {
		print "no hosts to visit ...\n";
		return 1;
	}

	# while worker is free start worker with work
	while ($dispatcher->free_workers) {

	}

	return 0;
}

sub on_work_yield {
	my $dispatcher = shift;
	# digest_ref
	# digest_path
	
	# if new ref is found and space to load another host, try load host
	# if worker is free, try start worker with new found path / root host node
	return 0;
}

sub on_work_success {
	my $dispatcher = shift;
	# work is done 
	# mark path as done
	
	# start worker if work is available
	# if no work is available, end
	return 0;
}

sub on_work_error {
	my $dispatcher = shift;
	my $error = shift;
	# work is done 
	# mark path as error
	
	# start worker if work is available
	# if no work is available, end
	return 0;
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
	my ($worker, $hostid, $hostname, $port, $path) = @_;

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
			$worker->yield("r", $hostid, $host, $port || 70) if $protocol eq "gopher" and $host ne $hostname;
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
			$worker->yield("p", $hostid, $rowtype, $rowpath);
		}
		else {
			# reference to foreign host
			$worker->yield("r", $hostid, $rowhost, $rowport);
		}
	}

	# close tcp socket
	close($socket);
	return 0;
}

# a reference to local path on the same host
sub digest_path {
	my ($host, $type, $path) = @_;
	my ($addet, $ep) = host_add_endpoint($host, $type, split(/\//, $path));
	foreach (@$addet) {
		if ($_->gophertype eq "1") { # if its a gopherpage, check it out later
			push(@{$host->unvisited}, $_);
		}
		$_->dbid($DATA->add_endpoint($host->dbid, $type, get_path_from_node($_), 0));
		print "~ PATH: $type $path\n";
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
	$DATA->increment_reference($host->dbid, $id);
}

sub split_host_port {
	my $str = shift @_;
	my ($host, $port) = $str =~ m/(^[a-z0-9-\.]+):?(\d+)?/gi;
	return ($host, 70) unless defined $port;
	return ($host, $port);
}

sub host_add_endpoint {
	my ($host, $type, @segments) = @_;
	my $current = $host->root;
	my @newendpoints = ();

	return ([], undef) if scalar(@segments) > CONFIG->{max_depth};

	if (not defined $current) {
		$current = PathNode->new();
		$current->name("");
		$current->gophertype("1");
		$host->root($current);
		push @{\@newendpoints}, $current;
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

			push @{$current->childs}, $found;
			push @{\@newendpoints}, $found;
		}
		$current = $found;
	}
	# set the last segments type and id ... O~O
	$current->gophertype($type);
	return (\@newendpoints, $current);
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
	my ($hostname, $port) = split_host_port($DATA->get_host_from_id($hostid));

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);
	$host->dbid($hostid);

	$host->root(undef);

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = $DATA->get_endpoints_from_host($host->dbid);
	foreach (@$rows) {
		my ($addet, $endpoint) = host_add_endpoint($host, @$_[2], split(/\//, @$_[3]));
		if (@$addet == 0) { # if its already in the cache
			print "duplicate endpoint in database or too many segments:\n";
			print @$_[3], "\n";
			next;
		}
		$endpoint->dbid(@$_[0]);
		if (@$_[4] == 0 && @$_[2] == 1) { # if unvisited and is a gopher page
			push @{$host->unvisited}, $endpoint; # add to unvisited
		}
	}
	print "Done!\n";

	# check if the root is already in, if not add it. 
	my ($addet, $root) = host_add_endpoint($host, "1", split(/\//, ""));
	if (@$addet > 0) {
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
