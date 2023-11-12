package Data;

use DBI;

sub new {
	my ($class,$args) = @_;
	my $self = bless { }, $class;
}

sub init {
	my($self, $path) = @_;
	if($path =~ m/[' ""]/i){
		die "invalid database path!"
	}
	my $db = DBI->connect("dbi:SQLite:dbname=$path","","", {PrintError => 1, foreign_keys => 1}) or die('database error: ' . DBI->errstr());

	# enforce database schema
	$db->do("create table if not exists hosts(id INTEGER PRIMARY KEY, host TEXT not null unique, status INT not null);");
	$db->do("create table if not exists endpoints(id INTEGER PRIMARY KEY, hostid INT, type CHAR(1), path TEXT, status INT not null, FOREIGN KEY(hostid) REFERENCES hosts(id));");
	$db->do("create table if not exists refs(pair TEXT PRIMARY KEY, count INT not null);");

	# indexing hosts
	my $sth = $db->prepare("select * from hosts");
	$sth->execute();
	while(($id, $host, undef) = $sth->fetchrow()){
   		$self->{host_ids}->{$host} = $id;
	}
	
	$self->{prepared} = {
		add_endpoint => $db->prepare("insert into endpoints (hostid, type, path, status) VALUES(?, ?, ?, ?)")
	};
	$self->{dbh} = $db;
}

sub disconnect {
	my $self = shift;
	$self->{dbh}->disconnect;
}

sub get_host_id {
	my($self, $host, $port) = @_;
	return $self->{host_ids}->{"$host:$port"};
}

# ### HOSTS:

sub register_new_host {
	my($self, $host, $port) = @_;
	my $sth = $self->{dbh}->prepare("insert into hosts (host, status) values (?, ?);");
	$sth->execute("$host:$port", 0);
	my $id = $self->{dbh}->sqlite_last_insert_rowid;
   	$self->{host_ids}->{"$host:$port"} = $id;
	return $id;
}

sub is_host_registered {
	my($self, $host, $port) = @_;
	return 1 if defined get_host_id($self, $host, $port);
	return 0;
}

sub get_first_host_unvisited {
	my $self = shift;
	my $sth = $self->{dbh}->prepare("select id, host from hosts where status=0 LIMIT 1");
	$sth->execute;
	return $sth->fetchrow_array;
}

sub get_host_from_id {
	my ($self, $id) = @_;
	my $sth = $self->{dbh}->prepare("select host from hosts where id=? LIMIT 1");
	$sth->execute($id);
	return $sth->fetchrow_array;
}

sub set_host_status {
	my($self, $id, $status) = @_;
	print "host: $id done: $status\n";
	my $sth = $self->{dbh}->prepare("update hosts set status=? where id=?");
	$sth->execute($status, $id);
}

sub get_all_unvisited_hostids {
	my $self = shift;
	my $sth = $self->{dbh}->prepare("select id from hosts where status=0");
	$sth->execute();
	my @res;
	while(my $id = $sth->fetchrow()){
   		push @res, $id;
	}
	return @res;
}


# ### ENDPOINTS:

sub add_endpoint {
	my($self, $hostid, $type, $path, $status) = @_;
	$self->{prepared}->{add_endpoint}->execute($hostid, $type, $path, $status);
	return $self->{dbh}->last_insert_id();
}

sub set_endpoint_status {
	my($self, $id, $status) = @_;
	my $sth = $self->{dbh}->prepare("update endpoints set status=? where id=?");
	$sth->execute($status, $id);
}

sub get_endpoints_where_status {
	my($self, $host, $port, $status) = @_;
	my $sth = $self->{dbh}->prepare("select * from endpoints where hostid=? and status=?");
	$sth->execute(get_host_id($self, "$host:$port"), $status);
	return $sth->fetchall_arrayref();
}

sub get_endpoints_from_host {
	my($self, $hostid) = @_;
	my $sth = $self->{dbh}->prepare("select * from endpoints where hostid=?");
	#prompt($hostid);
	$sth->execute($hostid);
	return $sth->fetchall_arrayref();
}

# ### REFERENCES:

sub refs_get_count {
	my($self, $from_host, $from_port, $to_host, $to_port) = @_;
	my $sth = $self->{dbh}->prepare("select * from refs where pair=? LIMIT 1");
	$sth->execute("$from_host:$from_port=>$to_host:$to_port");
	my(undef, $count) = $sth->fetchrow_array;
	unless(defined $count){
		return 0;
	}
	return $count;
}

sub increment_reference {
	my($self, $from_host, $from_port, $to_host, $to_port) = @_;
	my $count = refs_get_count($self, $from_host, $from_port, $to_host, $to_port);
	unless($count){
		$self->{dbh}->do("insert into refs (pair, count) values (?, ?)", undef, "$from_host:$from_port=>$to_host:$to_port", 1); # insert new row
		return;
	}
	$self->{dbh}->do("update refs set count=? where pair=?", undef, $count+1, "$from_host:$from_port=>$to_host:$to_port");
}

1;