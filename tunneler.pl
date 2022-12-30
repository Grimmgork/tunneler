use strict;
use Class::Struct;
use IO::Socket::INET;
use IO::Select;
use Net::Ping;
use List::Util 'first';
use threads;
use Win32::Pipe;

require './data.pl';
require './worker.pl';


# ~ CONFIGURATION:
use constant PING		=> "8.8.8.8";
use constant FILE_DB	=> "gopherspace.db";
use constant FILE_STAT	=> "status.txt";
use constant MAX_DEPTH	=> 4;
use constant MAX_WORKERS	=> 10;


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

struct WorkRequest => {
	host => '$',
	node => '$',
	thr => '$'
};

# my $thr = threads->create('request_worker', "gopher.floodgap.com", 70, "");
# my $res = $thr->join();

# my ($status, $paths, $references) = @$res;
# print "status: $status\n";
# foreach(@$paths){
# 	print "$_\n";
# }
# foreach(@$references){
# 	print "$_\n";
# }
# exit();

#   my $host = Host->new();
#   $host->name("sdf.org");
#   $host->port(70);

#   # try_add_path_to_endpoints($host, "1", split(/\//, "/kek/kle"));
#   #my ($endpoints, $node) = try_add_path_to_endpoints($host, "1", split(/\//, "/kek/kle/lol"));
#   my ($endpoints, $node) = try_add_path_to_endpoints($host, "1", split(/\//, "/kek/kle/lol"));
#   print get_full_endpoint_path($node), "\n";
#   my $ep = $node;
#   while($ep){
#  	print $ep->name, "\n";
#  	if(defined $ep->parent){
#  		$ep = $ep->parent;
#  	}
#  	else{
#  		last;
#  	}
#  }
#  exit();
#print clean_path("  kek///[]lel/kok/ ");
#exit();

print "INDEXING ...\n";
data_connect(FILE_DB);
print "DONE!\n";

unless(data_get_first_host_unvisited()){
	my ($host, $port) = split_host_port(prompt("host:port?"));
	$port = 70 unless defined $port;
	data_register_new_host($host, $port);
}

my %requests; # map between hostid and request
my %hosts; # map hostid to host object

# main loop
while(1){
	# load hosts
	my $left = MAX_WORKERS - scalar keys %requests;
	if($left > 0){
		my @hostids = get_other_hostids_not_finished($left, keys %requests);
		foreach(@hostids){
			$requests{$_} = undef;
			$hosts{$_} = load_host_from_database($_);
			print "host id:$_ loadet!\n";
		}
	}

	my @done; # list of finished requests

	# find finished/empty requests and start new ones
	foreach(keys %requests){
		my $res = $requests{$_};
		if(defined $res){
			next if $res->thr->is_running; # skip if its still running
			push @done, $res; # add finished request to the 'done' list
		}

		$requests{$_} = undef;
		# try start a new request
		my $host = $hosts{$_};
		my $node = shift(@{$host->unvisited}); # pick next endpoint
		if($node){
			# generate a new request for host
			my $path = get_full_endpoint_path($node);
			my $req = WorkRequest->new();
			$req->host($host);
			$req->node($node);
			$req->thr(threads->create('request_worker', $host->name, $host->port, $path));
			$requests{$_} = $req;
			print "started a new request: $path\n";
		}
		else{
			# no more endpoints to visit
			unless(defined $res){# if there is no response to digest 
				# host is fully discovered
				data_set_host_status($host->dbid, 1);
				# remove host
				delete $requests{$host->dbid};
				delete $hosts{$host->dbid};
			}
		}
	}

	# work on results
	foreach(@done){
		my $res = $_->thr->join();
		my ($status, $paths, $refs) = @$res; # get result
		print "$status\n";
		digest_discoveries($_->host, $paths, $refs) unless $status > 0;
		data_set_endpoint_status($_->node->dbid, 1 + $status);
	}

	# prompt("iteration ...");
}

data_disconnect();
print "no more hosts to visit!";
1;

sub remove_first_from_array{
	my ($obj, @arr) = @_;
	foreach my $index (0 .. $#arr){
		if($arr[$index] == $obj){
			delete $arr[$index];
			last;
		}
	}
	return @arr;
}

sub contains{
	my ($obj, @arr) = @_;
	foreach(@arr){
		return 1 if $_ == $obj; 
	}
	return 0;
}

sub digest_discoveries{
	my ($host, $paths, $refs) = @_;

	foreach(@$paths){
		my ($type, $path) = $_ =~ /^(.)(.*)$/;
		my ($addet, $ep) = try_add_path_to_endpoints($host, $type, split(/\//, $path));
		foreach my $endpoint (@$addet){
			if($endpoint->gophertype eq "1"){ # if its a gopherpage, check it out later
				push(@{$host->unvisited}, $endpoint);
			}
			$endpoint->dbid(data_add_endpoint($host->dbid, $type, get_full_endpoint_path($endpoint), 0));
			print "$type $path\n";
		}
	}

	foreach(@$refs){
		if(my ($url) = $_ =~ /^URL:(.+)/i){
			data_increment_reference($host->name, $host->port, "URL", $url);
			print " ~ URL: $url\n";
			next;
		}
		my ($hostname, $port) = split(/:/, $_, 2);
		if(defined try_register_host($hostname, $port)){
			print " * DICOVERED: $hostname:$port\n";
		}
		data_increment_reference($host->name, $host->port, $hostname, $port);
		print " ~ REF: $hostname:$port\n";
	}
}

sub get_other_hostids_not_finished{
	my ($n, @blacklist) = @_;
	my @ids = data_get_all_unvisited_hostids();
	my @res;
	foreach(@ids){
		push @res, $_ unless contains($_, @blacklist);
		last if scalar @res >= $n;
	}
	return @res;
}

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
	my ($host, $type, @segments) = @_;
	my $current = $host->root;
	my @newendpoints = ();

	if(scalar(@segments) > MAX_DEPTH){
		my @kek;
		return (\@kek, undef);
	}

	if(not defined $current){
		$current = PathNode->new();
		$current->name("");
		$current->gophertype("1");
		$host->root($current);
		push @{\@newendpoints}, $current;
	}

	# assume there is always a empty root segment
	shift(@segments);
	
	foreach my $segment ( @segments ) {
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
	# set the last segments type and id ... O~O
	$current->gophertype($type);
	return (\@newendpoints, $current);
}

sub get_full_endpoint_path{
	# $_[0] = the leaf node
	unless(defined $_[0]->parent){
		return $_[0]->name;
	}
	my $name = $_[0]->name;
	my $path = get_full_endpoint_path($_[0]->parent);
	return "$path/$name";
}

sub load_host_from_database{
	my ($hostid) = @_;
	my ($hostname, $port) = split_host_port(data_get_host_from_id($hostid));

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);
	$host->dbid($hostid);

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = data_get_endpoints_from_host($host->dbid);
	foreach(@$rows){ # TODO $row to $_
		my ($addet, $endpoint) = try_add_path_to_endpoints($host, @$_[2], split(/\//, @$_[3]));
		if(@$addet == 0){ # if its already in the cache
			print "duplicate endpoint in database or too many segments:\n";
			print @$_[3], "\n";
			next;
		}
		$endpoint->dbid(@$_[0]);
		if(@$_[4] == 0 && @$_[2] == 1){ # if unvisited and is a gopher page
			push @{$host->unvisited}, $endpoint; # add to unvisited
		}
	}
	print "Done!\n";

	# check if the root is already in, if not add it. 
	my ($addet, $root) = try_add_path_to_endpoints($host, "1", split(/\//, ""));
	if(@$addet > 0){
		push @{$host->unvisited}, $root;
	}

	return $host;
}

sub traverse_host{
	my ($host) = @_;

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = data_get_endpoints_from_host($host->dbid);
	foreach(@$rows){ # TODO $row to $_
		my ($addet, $endpoint) = try_add_path_to_endpoints($host, @$_[2], split(/\//, @$_[3]));
		if(@$addet == 0){ # if its already in the cache
			print "duplicate endpoint in database or too many segments:\n";
			print @$_[3], "\n";
			next;
		}
		$endpoint->dbid(@$_[0]);
		if(@$_[4] == 0 && @$_[2] == 1){ # if unvisited and is a gopher page
			push @{$host->unvisited}, $endpoint; # add to unvisited
		}
	}
	print "Done!\n";

	# check if the root is already in, if not add it. 
	my ($addet, $root) = try_add_path_to_endpoints($host, "1", split(/\//, ""));
	if(@$addet > 0){
		push @{$host->unvisited}, $root;
	}

	my $lastreport = time();
	# check out every gopher page until the unvisited list is empty
	while(my $node = shift(@{$host->unvisited})){
		my $err = traverse_gopher_page($host, get_full_endpoint_path($node));
		my $id = $node->dbid;
		data_set_endpoint_status($node->dbid, 1 + $err);
		
		unless(FILE_STAT){
			next;
		}

		# report after 5 seconds
		if(time()-$lastreport > 5){
			report_status($host);
			$lastreport = time();
		}
	}

	data_set_host_status($host->dbid, 1);
	return $host;
}

sub report_status{
	my ($host) = @_;
	my $hostname = $host->name;
	my $port = $host->port;
	my $unvisited = @{$host->unvisited};

	my $msg = <<EOF;
# TUNNELER STATUS:
host: $hostname
port: $port
stack: $unvisited
EOF
	open(my $h, '>', FILE_STAT) or return;
	print $h $msg;
	close($h);
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
	return "/$path";
}

sub has_internet_connection{
	my $p = Net::Ping->new('tcp');
	$p->port_number(443);
	my $res = $p->ping(PING);
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
	if ($@ =~ /^[13]/) {
		return 3; # external error
	}

	# iterate rows
	foreach(@rows) {
		# print "processing line ...!\n";
		# $_ holds the text of the current row
		last if($_ eq "."); # end of gopher page

		my ($rowtype, $rowpath, $rowhost, $rowport) = $_ =~ /^([^i3\s])[^\t]*\t([^\t]*)\t([^\t]*)\t(\d+)/; # <- TODO ERROR HERE!!!
		unless(defined $rowtype){
			next;
		}

		if(my ($url) = $rowpath =~ m/UR[LI]:(.+)/gi)
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
		# exclude invalid host names including ftp.* and *.onion names
		if($rowhost =~ /[^a-z0-9-\.]|ftp\.|\.onion/i){
			next;
		}

		if($rowhost eq ""){
			$rowhost = $host->name;
			if($rowport eq ""){
				$rowport = $host->port;
			}
		}

		if(($rowhost eq $host->name) && ($rowport eq $host->port))
		{ # endpoint of current host
			# make sure all endpoints of path are discovered
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