use strict;
use Class::Struct;

struct Host => {
	name => '$',
	port => '$',
	visited => '$',
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

sub try_add_empty_host{
	my ($host, $port) = @_;
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
	print "traversing host!\n";

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	traverse_gopher_page($host);
	
	return $host;
}

sub traverse_gopher_page{
	my($host, $path) = @_;

	unless(defined $path){
		$path = "";
	}

	# make request recursively
}

sub request_gopher{
	# request gopher page 
	# map all endpoints
	# register all other hosts
	# recursively call request gopher on all other gopher pages
}