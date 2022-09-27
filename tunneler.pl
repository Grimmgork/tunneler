use strict;
use Class::Struct;
use IO::Socket::INET;

struct Host => {
	name => '$',
	port => '$',
	refs => '%',
	endpoints => '%'
};

struct PathSegment => {
	parent => '$',
	children => '@',
	type => '$',
	dirty => '$'
};

while(1) {
	my $filename;
	$filename = &pick_unvisited_host;
	unless(defined $filename){
		last;
	}

	my ($hostname, $port) = filename_to_host($filename);
	print "### START HOST: $hostname:$port ###\n";
	my $host = traverse_host($hostname, $port);
	write_host($host, $filename);
}

sub pick_unvisited_host{
	my $dirname = '.';
	opendir(DIR, $dirname) or die "Could not open $dirname\n";

	my $result;
	my $filename;
	while ($filename = readdir(DIR)) {
  		next unless -f $filename;
		if(&is_host_unvisited(filename_to_host($filename))){
			$result = $filename;
			last;
		}
	}
	closedir(DIR);
	return $result;
}

sub filename_to_host{
	my $filename = shift @_;
	return ($filename =~ m/(^[a-zA-Z0-9-\.]+)#(\d+)/);
}

sub host_to_filename{
	my ($host, $port) = @_;
	$host =~ s/[^a-z\d\-.]//gi;
	$port =~ m/\d+/;
	return "$host#$port.txt";
}

sub is_host_unvisited{
	my ($hostname, $port) = @_;
	return -z host_to_filename($hostname, $port);
}

sub is_host_registered{
	my ($hostname, $port) = @_;
	return -e host_to_filename($hostname, $port);
}

sub register_unvisited_host{
	my ($hostname, $port) = @_;
	{ open my $handle, '>', host_to_filename($hostname, $port) }
}

sub write_host{
	my ($host, $filename) = @_;

	open(my $fh, '>', $filename) or die "Could not open file '$filename' $!";
	printf $fh "%s\n", $host->name;
	printf $fh "%s\n", $host->port;
	print $fh "#REF\n";
	my @refs = keys %{$host->refs};
	if(@refs > 0){
		print $fh join("\n", @refs);
		print $fh "\n";
	}
	print $fh "#STRUCT";
	my @endpts = keys %{$host->endpoints};
	if(@endpts > 0){
		print $fh "\n";
		print $fh join("\n", @endpts);
	}
	close $fh;
}

sub traverse_host{
	my ($hostname, $port) = @_;

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	traverse_gopher_page_recursively($host, "", 3); # recursively traverse all gopher pages of server, starting with the index page "/".
	
	return $host;
}

sub trim{
	my($str) = @_;
	$str =~ s/^\s+|\s+$//g;
	return $str;
}

sub rm_trailing_slash{
	my($str) = @_;
	$str =~ s{/$}{};
	return $str;
}

sub clean_path{
	my ($path) = @_;
	$path = trim($path);
	if($path eq "" || $path eq "/"){
		return "/";
	}
	unless(defined $path){
		return "/";
	}
	return rm_trailing_slash($path);
}

sub traverse_gopher_page_recursively{
	my($host, $path, $depth) = @_;

	if($depth < 0 || $path =~ /(\/commit\/|archive|git)/gi){ # dont wander into deep, dark caverns ... 0~0
		${$host->endpoints}{"1#SKIP#$path"} = 1;
		printf " -> SKIP: %s:%s 1%s\n", $host->name, $host->port, $path;
		return 0;
	}

	$path = clean_path($path);

	# request gopher page
	my @rows;
	eval{
		@rows = request_gopher($host->name, $host->port, $path);
	};
	if ($@) {
		print " X ERROR\n";
		<STDIN>;
		return 0;
	}

	#push(@{$host->endpoints}, "1$path");
	${$host->endpoints}{"1$path"} = 1;
	printf " -> MAP: %s:%s 1%s\n", $host->name, $host->port, $path;
	
	# iterate all endpoints
	foreach my $row (@rows) {
		# register unknown hosts
		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^(.)([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;
		$rowpath = clean_path($rowpath);
		$rowhost = trim($rowhost);
		$rowport = trim($rowport);

		if($rowtype eq "i" || $rowtype eq "3" || $rowtype eq ""){
			next;
		}

		unless((defined $rowhost) && (defined $rowport)){
			next;
		}

		if(($rowhost eq "") && ($rowport eq "")){
			next;
		}

		if(($rowhost eq $host->name) && ($rowport eq $host->port)){ # link is on the current host
			# register endpoint
			my $pathref = "$rowtype$rowpath";
			unless(${$host->endpoints}{$pathref}) {
				${$host->endpoints}{"$pathref"} = 1;
				print "$pathref\n";

				if($rowtype eq "1"){
					traverse_gopher_page_recursively($host, $rowpath, $depth-1)
				}
			}
		}
		else # link to another host
		{
			# register host if unknown
			unless(is_host_registered($rowhost, $rowport)){
				${$host->refs}{"$rowhost:$rowport"} = 1;
				register_unvisited_host($rowhost, $rowport);
				print " * DICOVERED: $rowhost:$rowport\n";
			}
		}
	}

	return 1;
}

sub request_gopher{
	my($hostname, $port, $path) = @_;

	my $socket = new IO::Socket::INET (
    		PeerHost => $hostname,
    		PeerPort => $port,
    		Proto => 'tcp',
		Timeout => 10
	);

	$socket->send("$path\n");
	local $SIG{ALRM} = sub { die "timeout" };
	my @result;
	eval{
		alarm 10;
		@result = <$socket>;
	};
	close($socket);
	alarm 0;

	return @result;
}