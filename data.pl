use DBI;

my %HOST_IDS;

sub data_connect{
	my($path) = @_;
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
   		$HOST_IDS{$host} = $id;
	}
	
	return $db;
}

sub data_disconnect{
	my($db) = @_;
	$db->disconnect;
}

sub data_commit{
	my($db) = @_;
	$db->commit() or die $dbh->errstr;
}

sub data_get_host_id{
	my($host, $port) = @_;
	return $HOST_IDS{"$host:$port"};
}

# ### HOSTS:

sub data_register_new_host{
	my($db, $host, $port) = @_;
	my $sth = $db->prepare("insert into hosts (host, status) values (?, ?);");
	$sth->execute("$host:$port", 0);
	my $id = $db->sqlite_last_insert_rowid;
   	$HOST_IDS{"$host:$port"} = $id;
	return $id;
}

sub data_is_host_registered{
	my($host, $port) = @_;
	return 1 if defined data_get_host_id($host, $port);
	return 0;
}

sub data_get_first_host_unvisited{
	my($db) = @_;
	my $sth = $db->prepare("select (host) from hosts where status=0 LIMIT 1");
	$sth->execute;
	return $sth->fetchrow_array;
}

sub data_set_host_status{
	my($db, $host, $port, $status) = @_;
	my $sth = $db->prepare("update hosts set status=? where host=?");
	$sth->execute($status, "$host:$port");
}


# ### ENDPOINTS:

my %endpoint_cache;

sub data_add_endpoint{
	my($db, $host, $port, $type, $path, $status) = @_;
	my $sth = $db->prepare("insert into endpoints (hostid, type, path, status) VALUES(?, ?, ?, ?)");
	$sth->execute(data_get_host_id($host, $port), $type, $path, $status);
}

sub data_set_endpoint_status{
	my($db, $id, $status) = @_;
	my $sth = $db->prepare("update endpoints set status=? where id=?");
	$sth->execute($status, $id);
}

sub data_get_endpoints_where_status{
	my($db, $host, $port, $status) = @_;
	my $sth = $db->prepare("select * from endpoints where hostid=? and status=?");
	$sth->execute(data_get_host_id("$host:$port"), $status);
	return $sth->fetchrow_array;
}

sub data_is_endpoint_registered{
	my($db, $host, $port, $path) = @_;
	my $sth = $db->prepare("select * from endpoints where hostid=? and path=? LIMIT 1");
	$sth->execute(data_get_host_id("$host:$port"), $path);
	if($sth->fetchrow_array){
		return 1;
	}
	return 0;
}

sub data_clear_endpoint_cache{
	%{$endpoint_cache} = ();
}

sub data_load_endpoint_cache{
	my ($db, $host, $port) = @_;
	my $sth = $db->prepare("select * from endpoints where hostid=? and path=?");
	$sth->execute("$host:$port", $path);
	while(($lname,$fname,$ext) = $sth->fetchrow()){
   		print("$lname, $fname\t$ext\n");                   
	}
}

sub data_check_endpoint_cache{
	my ($host, $port, $path) = @_;
	return defined $endpoint_cache{"$host:$port#$path"};
}

# ### REFERENCES: 

sub data_refs_get_count{
	my($db, $from_host, $from_port, $to_host, $to_port) = @_;
	my $sth = $db->prepare("select * from refs where pair=? LIMIT 1");
	$sth->execute("$from_host:$from_port=>$to_host:$to_port");
	my ($hosts, $count) = $sth->fetchrow_array;
	unless(defined $hosts){
		return 0;
	}
	return $count;
}

sub data_increment_reference{

	my($db, $from_host, $from_port, $to_host, $to_port) = @_;
	my $count = data_refs_get_count($db, $from_host, $from_port, $to_host, $to_port);
	unless($count){
		$db->do("insert into refs (pair, count) values (?, ?)", undef, "$from_host:$from_port=>$to_host:$to_port", 1); # insert new row
		return;
	}

	$db->do("update refs set count=? where pair=?", undef, $count+1, "$from_host:$from_port=>$to_host:$to_port");
}

1;