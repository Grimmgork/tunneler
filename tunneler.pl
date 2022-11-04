use strict;
use Class::Struct;
use IO::Socket::INET;
use IO::Select;
use Net::Ping;
use List::Util 'first';

require './data.pl';

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

#  my $host = Host->new();
#  $host->name("sdf.org");
#  $host->port(70);

#  my ($endpoints, $node) = try_add_path_to_endpoints($host, "1", split(/\//, "/kek/kle"));
#  my $count = @{$endpoints};
#  print "$count\n";
#  print "$node\n";
#  print clean_path("//kek/lel");
#  exit();

my $PING = "8.8.8.8";
print "INDEXING ...\n";
data_connect("gopherspace.db");
print "DONE!\n";

# data_set_endpoint_status(1, "0");

# prompt user for a host if no unvisited host is in the database
unless(data_get_first_host_unvisited()){
	my $inpt = defined $ARGV[0] ? $ARGV[0] : prompt("host:port?");
	my ($host, $port) = split_host_port($inpt);
	data_register_new_host($host, $port);
}

# main loop
while(my ($id, $hostandport) = data_get_first_host_unvisited()) {
	my ($hostname, $port) = split_host_port($hostandport);
	print "### START HOST: id:$id $hostname:$port ###\n";
	# init picked host
	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);
	$host->dbid($id);

	traverse_host($host);
}

data_disconnect();
1;

sub split_host_port{
	my $str = shift @_;
	my ($host, $port) = $str =~ m/(^[a-z0-9-\.]+):?(\d+)?/gi;
	return ($host, 70) unless(defined $port);
	return ($host, $port);
}

sub try_register_host{
	my ($hostname, $port) = @_;
	return undef if(data_is_host_registered($hostname, $port));
	return data_register_new_host($hostname, $port);
}

sub try_add_path_to_endpoints{
	my ($host, $type, @segments, $max_depth) = @_;
	my $current = $host->root;
	my @newendpoints = ();
	if(not defined $current){
		$current = PathNode->new();
		$current->name("");
		$current->gophertype("1");
		$host->root($current);
		push @{\@newendpoints}, $current;
		shift @segments;
	}
	
	my $i = 0;
	foreach my $segment ( @segments ) {
		$i++;
		# search children
		my $found = undef;
		foreach (@{$current->childs}){
			if($_->name eq $segment){
				$found = $_;
				last;
			}
		}
		unless(defined $found){
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
	if($i == @segments){
		$current->gophertype($type); # set the last segment as the type ... 0~0
	}
	return (\@newendpoints, $current);
}

sub get_full_endpoint_path{
	my ($node) = @_;
	bless $node, "PathNode";
	unless(defined $node->parent){
		return $node->name;
	}
	my $name = $node->name;
	my $path = get_full_endpoint_path($node->parent);
	return "$path/$name";
}

sub traverse_host{
	my ($host) = @_;

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = data_get_endpoints_from_host($host->dbid);
	foreach my $row (@$rows){
		my ($addet, $endpoint) = try_add_path_to_endpoints($host,  @$row[2], @$row[3]);
		if(@$addet == 0){ # if its already in the cache
			print "duplicate endpoint in database!\n";
			next;
		}
		$endpoint->dbid(@$row[0]);
		if(@$row[4] == 0 && @$row[2] == 1){ # if unvisited and is a gopher page
			push @{$host->unvisited}, $endpoint; #add to unvisited
		}
	}
	print "Done!\n";

	# check if the root is already in, if not add it. 
	my ($addet, $root) = try_add_path_to_endpoints($host, "1", split(/\//, ""));
	if(@$addet != 0){
		push @{$host->unvisited}, $root;
	}
	
	# check out every gopher page until the unvisited list is empty
	while(my $node = shift(@{$host->unvisited})){
		my $err = traverse_gopher_page($host, get_full_endpoint_path($node));
		my $id = $node->dbid;
		data_set_endpoint_status($node->dbid, 1 + $err);
	}

	data_set_host_status($host->dbid, 1);
	return $host;
}

sub prompt{
	my($message) = @_;
	print "$message\n";
	my $res = <STDIN>;
	chomp $res;
	return $res;
}

sub trim{
	my($str) = @_;
	$str =~ s/^\s+|\s+$//g;
	return $str;
}

sub clean_path{
	my ($path) = @_;
	$path =~ s/\\/\//g; #replace \ with /
	$path =~ s/^[\s\/]+|[\/\s]+$//g; #trim right / and left + right withespaces
	if($path eq ""){
		return "";
	}
	$path = "/$path";
	return $path;
}

sub has_internet_connection{
	my $p = Net::Ping->new('tcp');
	$p->port_number(443);
	my $res = $p->ping($PING);
	$p->close();
	return $res;
}

sub wait_for_internet_connection{
	sleep(3);
	until(has_internet_connection()){
		sleep(3);
	}
}

sub traverse_gopher_page{
	my($host, $path) = @_;

	printf " -> ENTER: %s:%s 1%s\n", $host->name, $host->port, $path;

	# try request gopher page
	my @rows;
	eval{
		@rows = request_gopher($host->name, $host->port, $path);
	};
	if ($@) {
		return 3; # external error
	}

	# iterate rows
	foreach my $row (@rows) {
		last if($row eq "."); # end of gopher page

		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^([^i3])([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;
		unless(defined $rowtype){ # rowtype i and 3 and invalid rows are ignored
			next;
		}

		if(my ($url) = $rowpath =~ m/^UR[LI]:(.*)/gi)
		{ # extract a full url reference like: URL:http://example.com
			my($protocol, $hostname) = $url =~ m/^([a-z0-9]*):\/\/([^\/:]*)/gi;
			if(defined $protocol){
				print " ~ REF: URL:$protocol://$hostname\n";
				data_increment_reference($host->name, $host->port, "URL:$protocol", "//$hostname"); # a little trick, the query will convert it to "URL:$protocol://$hostname"
			}
			next;
		}

		$rowpath = clean_path($rowpath);
		$rowhost = trim(lc $rowhost); # lowercase and trim the domain name

		# exclude invalid host names
		if($rowhost =~ /[^a-z0-9-\.]/i){
			next;
		}

		# exclude *.onion and ftp.* domains
		if($rowhost =~ /(^ftp\.|\.onion$)/gi){
			next;
		}

		if($rowhost eq ""){
			$rowhost = $host->name;
		}

		if($rowport eq ""){
			$rowport = $host->port;
		}

		if(($rowhost eq $host->name) && ($rowport eq $host->port))
		{ # endpoint of current host
			# make sure all endpoints of path are discovered
			print "$rowpath\n";
			my @segments = split(/\//, $rowpath);
			foreach(@segments){
				print "$_\n";
			}
			prompt();

			my ($addet, $ep) = try_add_path_to_endpoints($host, $rowtype, split(/\//, $rowpath));
			foreach my $endpoint (@$addet){
				if($endpoint->gophertype eq "1"){ # if its a gopherpage, check it out later
					push(@{$host->unvisited}, $endpoint);
				}
				$endpoint->dbid(data_add_endpoint($host->dbid, $rowtype, get_full_endpoint_path($endpoint), 0));
				print "$rowtype $rowpath\n";
			}
		}
		else
		{ # link to foreign host
			# make sure host is registered
			if(defined try_register_host($rowhost, $rowport)){ 
				print " * DICOVERED: $rowhost:$rowport\n";
			}
			data_increment_reference($host->name, $host->port, $rowhost, $rowport);
			print " ~ REF: $rowhost:$rowport\n";
		}
	}

	return 0;
}

sub request_gopher{
	my($hostname, $port, $path) = @_;

	my $socket = new IO::Socket::INET (
    		PeerHost => $hostname,
    		PeerPort => $port,
    		Proto => 'tcp',
		Timeout => 10
	);

	unless(defined $socket){
		die "CONNECTION";
	}

	$socket->send("$path\n");
	
	my $selector = new IO::Select();
	$selector->add($socket);

	unless(defined $selector->can_read(5)){
		close($socket);
		die "TIMEOUT!";
	}

	return <$socket>;
}