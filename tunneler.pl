use strict;
use Class::Struct;
use IO::Socket::INET;

struct Host => {
	name => '$',
	port => '$',
	refs => '@',
	endpoints => '@'
};

while(1) {
	my $filename;
	$filename = &pick_unvisited_host;
	unless(defined $filename){
		last;
	}

	my ($hostname, $port) = filename_to_host($filename);
	write_host(traverse_host($hostname, $port), $filename);
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
	print $fh "Host!\n";
	close $fh;
	print "written host!";
}

sub traverse_host{
	my ($hostname, $port) = @_;
	print "# $hostname:$port\n";

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	traverse_gopher_page($host, ""); # recursively traverse all gopher pages of server, starting with the index page (empty path).
	
	return $host;
}

sub traverse_gopher_page{
	my($host, $path) = @_;

	unless(defined $path){
		$path = "/";
	}

	$path =~ s/^\s+|\s+$//g; #trim the ends

	if($path eq ""){
		$path = "/";
	}

	sleep(1);
	print "$path\n";

	# request gopher page
	my @rows = request_gopher($host->name, $host->port, $path);
	
	# iterate all endpoints
	foreach my $row (@rows) {
		# register unknown hosts
		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^(.)([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;
		# map file endpoints

		unless($rowtype == "i" || $rowtype == "3"){
			if(($rowhost eq $host->name) && ($rowport == $host->port)){
				# link is on the current host
				# register endpoint
				my $pathref = "$rowtype$rowpath";
				unless( grep(/^$pathref$/, @{$host->endpoints})) {
					push(@{$host->endpoints}, $pathref);
					if($rowtype == "1"){					
						traverse_gopher_page($host, $rowpath);
					}
				}
			}
			else
			{
				# link to another host
				# register host if unknown
				unless(is_host_registered($rowhost, $rowport)){
					print "found another host: $rowhost $rowport\n";
					register_unvisited_host($rowhost, $rowport);
				}
			}
		}
	}
}

sub request_gopher{
	my($host, $port, $path) = @_;

	my $socket = new IO::Socket::INET (
    		PeerHost => $host,
    		PeerPort => $port,
    		Proto => 'tcp'
	);

	$socket->send("$path\n");
	# my $content = join('',<$socket>);

	return <$socket>;
}