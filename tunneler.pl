use strict;
use Class::Struct;
use IO::Socket::INET;
use IO::Select;
use Net::Ping;
use List::Util 'first';
use threads;
use Win32::Pipe;

use lib ".";

use Data;
use Worker;

# ~ CONFIG:
use constant CONFIG => {
	ping			=> "8.8.8.8",
	file_db		=> "gopherspace.db",
	file_stat		=> "status.txt",
	no_workers	=> 3,
	no_hosts		=> 1
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

print "INDEXING ...\n";
my $DATA = Data->new();
$DATA->init(CONFIG->{file_db});
print "DONE!\n";

unless($DATA->get_first_host_unvisited()){
	my ($host, $port) = split_host_port(prompt("host:port?"));
	$port = 70 unless defined $port;
	$DATA->register_new_host($host, $port);
}

# start workers and lay pipes ||=||
pipe(my $preader, my $cwriter) || die "pipe failed: $!";
$cwriter->autoflush(1);
my @pwriters;
for(1..CONFIG->{no_workers}){
	pipe(my $creader, my $pwriter) || die "pipe failed: $!";
	$pwriter->autoflush(1);
	push @pwriters, $pwriter;

	my $pid = fork(); # - fork
	unless($pid) { # child
		close $pwriter;
		close $preader;
		worker($creader, $cwriter);
		close $creader;
		close $cwriter;
		print "worker shutdown!\n";
		exit(0); # - fork end
	}
}
close $creader;
close $cwriter;
print "main started!\n";
main($preader, \@pwriters);
close $preader;
foreach(@pwriters){
	close $_;
}
print "main shutdown\n";

exit 0;

sub main {
	my ($reader, $writers) = @_;

	print $writers->[0] "start	sdf.org	70\n";
	while(<$reader>){
		print $_;
	}
}

sub worker {
	my ($reader, $writer) = @_;
	while(<$reader>){
		if($_ eq "start\n"){
			for(1..10){
				print $writer "test\n";
			}
			close $writer;
		}
	}
}

sub get_line {
	my ($socket, $timeout) = @_;
	wait_for_data($socket, $timeout || 5);
	my $res = <$socket>;
	chomp $res;
	return $res;
}

sub wait_for_data {
	my $selector = new IO::Select();
	$selector->add(shift);
	return undef unless defined $selector->can_read(shift);
	return 1;
}

my $hostindex;
my @hosts;
my $host;
# main loop
while(1) {
	# fill up hosts array
	my $l = @hosts;
	if($l < CONFIG->{no_hosts}){
		# add host
		my @hids = get_other_unvisited_hostids(CONFIG->{no_hosts} - $l, map { $_->dbid } @hosts);
		foreach(@hids){
			push @hosts, load_host_from_database($_);
		}
	}

	foreach(@worker_sockets){
		if(my $res = get_line($_, 0)){
			if(my ($code) = $res =~ /exit\t(\d)/){
				print "exit: $code\n";
				if($code eq "0"){
					$socket->send("get\n");
					wait_for_data($socket, 5);
					digest_response($host, $code, $socket); # TODO get host from response
				}
			}
		}
	}
	# go to next host
	
	# start idle worker

	# process respones

	sleep(1);
}

$DATA->disconnect();
print "no more hosts to visit!";
1;

sub remove_first_from_array {
	my ($obj, @arr) = @_;
	foreach my $index (0 .. $#arr){
		if($arr[$index] == $obj){
			delete $arr[$index];
			last;
		}
	}
	return @arr;
}

sub contains {
	my ($obj, @arr) = @_;
	foreach(@arr){
		return 1 if $_ == $obj; 
	}
	return 0;
}

sub digest_paths {
	my $ref = shift;
	my $paths;
	foreach(@$paths){
		my ($type, $path) = $_ =~ /^(.)(.*)$/;
		my ($addet, $ep) = try_add_path_to_endpoints($host, $type, split(/\//, $path));
		foreach my $endpoint (@$addet){
			if($endpoint->gophertype eq "1"){ # if its a gopherpage, check it out later
				push(@{$host->unvisited}, $endpoint);
			}
			$endpoint->dbid($DATA->add_endpoint($host->dbid, $type, get_full_endpoint_path($endpoint), 0));
			print "$type $path\n";
		}
	}
}

sub digest_refs {
	my $refs;
	foreach(@$refs){
		if(my ($url) = $_ =~ /^URL:(.+)/i){
			$DATA->increment_reference($host->name, $host->port, "URL", $url);
			print " ~ URL: $url\n";
			next;
		}
		my ($hostname, $port) = split(/:/, $_, 2);
		if(defined try_register_host($hostname, $port)){
			print " * DICOVERED: $hostname:$port\n";
		}
		$DATA->increment_reference($host->name, $host->port, $hostname, $port);
		print " ~ REF: $hostname:$port\n";
	}
}

sub get_other_unvisited_hostids {
	my ($n, @blacklist) = @_;
	my @ids = $DATA->get_all_unvisited_hostids();
	my @res;
	foreach(@ids){
		push @res, $_ unless contains($_, @blacklist);
		last if scalar @res >= $n;
	}
	return @res;
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

	# load all known endpoints for this host into cache
	print "Loading known endpoints for ", $host->name, " ", $host->port, " ...\n";
	my $rows = $DATA->get_endpoints_from_host($host->dbid);
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

sub traverse_host {
	my ($host) = @_;

	my $lastreport = time();
	# check out every gopher page until the unvisited list is empty
	while(my $node = shift(@{$host->unvisited})){
		my $err = traverse_gopher_page($host, get_full_endpoint_path($node));
		my $id = $node->dbid;
		$DATA->set_endpoint_status($node->dbid, 1 + $err);
		
		unless(CONFIG->{file_stat}){
			next;
		}

		# report after 5 seconds
		if(time()-$lastreport > 5){
			report_status($host);
			$lastreport = time();
		}
	}

	$DATA->set_host_status($host->dbid, 1);
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