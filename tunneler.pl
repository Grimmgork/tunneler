use strict;
use Class::Struct;
use IO::Socket::INET;
use IO::Select;
use Net::Ping;
use lib ".";

use threads;

use Data;
use Worker;

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
	unvisited => '@',
	priority => '$',
};

struct PathNode => {
	parent => '$',
	name => '$',
	gophertype => '$',
	childs => '@',
	dbid => '$'
};

struct WorkSlot => {
	worker => '$',
	id => '$',
	host => '$',
	node => '$',
	free => '$'
};

print "INDEXING ...\n";
my $DATA = Data->new();
$DATA->init(CONFIG->{file_db});
print "DONE!\n";

unless($DATA->get_first_host_unvisited()){
	my ($host, $port) = split_host_port(prompt("host:port?"));
	$port = 70 unless defined $port;
	$DATA->register_new_host($host, $port);
}

# start workers and lay pipes ~ ~ ~
my $reader, my $writer;
pipe($reader, $writer) || die "pipe failed: $!";
$writer->autoflush(1);
my @workers;
for(1..(CONFIG->{no_workers})) {
	my $worker = Worker->new($_, \&work);
	$worker->fork($writer);

	my $slot = WorkSlot->new();
	$slot->id($worker->{id});
	$slot->worker($worker);
	
	push @workers, $slot;
}
close $writer;
print "main started!\n";

my @hosts;

my $host = load_host_from_database(1);
$workers[0]->worker->work("sdf.org", 70, "");

_loop:
my $kek = <$reader>;
print $kek;
goto _loop;

my $id = <$reader>;
chomp $id;
my ($slot) = first(sub { $id == (shift)->id }, @workers);

my $type = <$reader>;
chomp $type;

# yield
if($type eq "y") {
	# process work yield
	my $find = <$reader>;
	chomp $find;
	my $host = $slot->host;
	if($find eq "p") { # local path
		my $gophertype = <$reader>;
		my $path = <$reader>;
		chomp $gophertype;
		chomp $path;
		digest_path($host, $gophertype, $path);
	}
	elsif($find eq "r") { # reference to another host
		my $ref = <$reader>;
		chomp $ref;
		digest_ref($host, $ref);
	}
}
# end
elsif($type eq "e") {
	my $error = <$reader>;
	chomp $error;
	my $node = $slot->node;
	$DATA->set_endpoint_status($node->dbid, (1 + $error));
	slot_free($slot);
}
# init
elsif($type eq "i") {
	slot_free($slot);
}

# foreach finished host
foreach(@hosts) {
	if(not (scalar @{$_->unvisited})) { # if no unvisited paths present 
		if(not where(sub { (shift)->host == $_ }, @workers)){ # no work for this host is pending
			$DATA->set_host_status($_->dbid, 1); # host is done
			@hosts = where(sub { not (shift) == $_; }, @hosts); # remove host from array
		}
	}
}

# try fill up hosts
while((scalar @hosts) < CONFIG->{no_hosts}) {
	my $id = get_unvisited_hostid(aggr(sub { (shift)->dbid }, @hosts));
	last if not $id;
	push @hosts, load_host_from_database($id);
}

# foreach free worker
	# try add request for top most host
	# rotate hosts
foreach(where(sub { (shift)->free }, @workers)) {
	my $host = shift @hosts;
	last unless $host;
	my $node = shift(@{$host->unvisited});
	slot_start_work($_, $host, $node) if $node;
	push @hosts, $host;
}

# end if no work left and no work is running
goto _loop;
print "no more hosts to visit!\n";

close $reader;
print "main shutdown\n";

$DATA->disconnect();
exit 0;
1;

sub slot_start_work {
	my ($slot, $host, $node) = @_;
	$slot->host($host);
	$slot->node($node);
	$slot->free(0);

	my $hostname = $host->name;
	my $port = $host->port;
	my $path = get_full_endpoint_path($node);
	$slot->worker->work($hostname, $port, $path);
}

sub slot_free {
	my $slot = shift;
	my $id = $slot->id;
	$slot->host(undef);
	$slot->node(undef);
	$slot->free(1);
}

sub contains {
	my ($obj, @arr) = @_;
	foreach my $item (@arr){
		return 1 if $item == $obj; 
	}
	return undef;
}

sub str_contains {
	my ($obj, @arr) = @_;
	foreach my $item (@arr){
		return 1 if $item eq $obj; 
	}
	return undef;
}

sub where {
	my $exp = shift;
	my @res;
	foreach my $item (@_) {
		push @res, $item if $exp->($item);
	}
	return @res;
}

sub first {
	my $exp = shift;
	foreach my $item (@_) {
		return $item if $exp->($item);
	}
}

sub aggr {
	my $exp = shift;
	my @res;
	foreach my $item (@_){
		push @res, $exp->($item);
	}
	return @res;
}

sub work {
	my ($worker, $hostname, $port, $path) = @_;

	# make request
	my $socket = new IO::Socket::INET (
    		PeerHost => $hostname,
    		PeerPort => $port,
    		Proto => 'tcp',
		Timeout => 5
	);

	return 1 unless defined $socket;

	$socket->send("$path\n");
	
	my $selector = new IO::Select();
	$selector->add($socket);
	unless(defined $selector->can_read(5)){
		close($socket);
		return 2;
	}

	my @refs;
	my @paths;

	# iterate rows
	foreach(<$socket>) {
		last if $_ eq "."; # end of gopher page

		my ($rowtype, $rowpath, $rowhost, $rowport) = $_ =~ /^([^i3\s])[^\t]*\t([^\t]*)\t([^\t]*)\t(\d+)/;
		next unless defined $rowtype;

		if(my ($url) = $rowpath =~ m/UR[LI]:(.+)/gi)
		{ # extract a full url reference like: URL:http://example.com
			my($protocol, $host) = $url =~ m/^([a-z0-9]*):\/\/([^\/:]*)/gi;
			if(defined $protocol) {
				$worker->yield("r", "URL:$protocol://$host");
			}
			next;
		}
		$rowpath = clean_path($rowpath);

		$rowhost = trim(lc $rowhost); # lowercase and trim the domain name
		# exclude invalid host names including ftp.* and *.onion names
		next if $rowhost =~ /[^a-z0-9-\.]|ftp\.|\.onion/i;

		if($rowhost eq "") {
			$rowhost = $hostname;
			if($rowport eq "") {
				$rowport = $port;
			}
		}

		if(($rowhost eq $hostname) && ($rowport eq $port)) { # endpoint of current host
			$worker->yield("p", $rowtype, $rowpath);
		}
		else { # reference to foreign host
			$worker->yield("r", "$rowhost:$rowport");
		}
	}

	# close tcp socket
	close($socket);
	return 0;
}

sub digest_path {
	my ($host, $type, $path) = @_;
	my ($addet, $ep) = try_add_path_to_endpoints($host, $type, split(/\//, $path));
	foreach(@$addet) {
		if($_->gophertype eq "1") { # if its a gopherpage, check it out later
			push(@{$host->unvisited}, $_);
		}
		$_->dbid($DATA->add_endpoint($host->dbid, $type, get_full_endpoint_path($_), 0));
		# print "~ PATH: $type $path\n";
	}
}

sub digest_ref {
	my ($host, $ref) = @_;
	if(my ($url) = $ref =~ /^URL:(.+)/i){
		$DATA->increment_reference($host->name, $host->port, "URL", $url);
		print " ~ URL: $url\n";
		return;
	}
	my ($hostname, $port) = split(/:/, $ref, 2);
	if(defined try_register_host($hostname, $port)){
		print " * DICOVERED: $hostname:$port\n";
	}
	$DATA->increment_reference($host->name, $host->port, $hostname, $port);
	print " ~ REF: $hostname:$port\n";
}

sub get_unvisited_hostid {
	my @ids = $DATA->get_all_unvisited_hostids();
	foreach(@ids) {
		return $_ if not contains($_, @_);
	}
	return undef;
}

sub split_host_port {
	my $str = shift @_;
	my ($host, $port) = $str =~ m/(^[a-z0-9-\.]+):?(\d+)?/gi;
	return ($host, 70) unless(defined $port);
	return ($host, $port);
}

sub try_register_host {
	my ($hostname, $port) = @_;
	return undef if($DATA->is_host_registered($hostname, $port));
	return $DATA->register_new_host($hostname, $port);
}

sub try_add_path_to_endpoints {
	my ($host, $type, @segments) = @_;
	my $current = $host->root;
	my @newendpoints = ();

	if(scalar(@segments) > CONFIG->{max_depth}){
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

sub get_full_endpoint_path {
	# $_[0] = the leaf node
	unless(defined $_[0]->parent){
		return $_[0]->name;
	}
	my $name = $_[0]->name;
	my $path = get_full_endpoint_path($_[0]->parent);
	return "$path/$name";
}

sub load_host_from_database {
	my ($hostid) = @_;
	my ($hostname, $port) = split_host_port($DATA->get_host_from_id($hostid));

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);
	$host->dbid($hostid);
	$host->priority(0);

	$host->root(undef);

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = $DATA->get_endpoints_from_host($host->dbid);
	foreach(@$rows) {
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

sub report_status {
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
	open(my $h, '>', CONFIG->{file_stat}) or return;
	print $h $msg;
	close($h);
}

sub prompt {
	my($message) = @_;
	print "$message\n";
	my $res = <STDIN>;
	chomp $res;
	return $res;
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

sub get_path_segments {
	my $path = shift;

}

sub has_internet_connection {
	my $p = Net::Ping->new('tcp');
	$p->port_number(443);
	my $res = $p->ping(CONFIG->{ping});
	$p->close();
	return $res;
}

sub wait_for_internet_connection {
	sleep(3);
	until(has_internet_connection()){
		sleep(3);
	}
}