package Data;

use DBI;

sub new {
	my $class = shift;
	my $self = bless { }, $class;
}

sub init {
	my ($self, $path) = @_;
	die "already connected!" if $self->{dbh};
	my $db = DBI->connect("dbi:SQLite:dbname=$path","","", { PrintError => 1, foreign_keys => 1 });

	# enforce database schema
	$db->do("create table if not exists hosts(id INTEGER PRIMARY KEY, host TEXT not null, port INT not null, status INT not null);");
	$db->do("create table if not exists endpoints(id INTEGER PRIMARY KEY, hostid INT, type CHAR(1), path TEXT, status INT not null, FOREIGN KEY(hostid) REFERENCES hosts(id));");
	$db->do("create table if not exists refs(hostid_from INTEGER, hostid_to INTEGER, count INT not null);");

	# indexing hosts
	my $sth = $db->prepare("SELECT id, host FROM hosts;");
	$sth->execute();
	while (($id, $host) = $sth->fetchrow()) {
   		$self->{known_hosts}->{$host} = $id;
	}
	
	$self->{prepared} = {
		add_endpoint => $db->prepare("INSERT INTO endpoints (hostid, type, path, status) VALUES(?, ?, ?, ?);")
	};

	$self->{dbh} = $db;
}

sub disconnect {
	my $self = shift;
	$self->{dbh}->disconnect if $self->{dbh};
}

sub get_host_id {
	my ($self, $host, $port) = @_;
	return $self->{known_hosts}->{"$host:$port"};
}

sub try_register_host {
	my ($self, $host, $port) = @_;
	return undef if defined get_host_id($self, $host, $port); # make sure host is not registered
	my $sth = $self->{dbh}->prepare("insert into hosts (host, port, status) values (?, ?, ?);");
	$sth->execute($host, $port, 0);
	my $id = $self->{dbh}->sqlite_last_insert_rowid;
   	$self->{known_hosts}->{"$host:$port"} = $id;
	return $id;
}

sub get_host_from_id {
	my ($self, $id) = @_;
	my $sth = $self->{dbh}->prepare("select host from hosts where id=? LIMIT 1");
	$sth->execute($id);
	return $sth->fetchrow_array;
}

sub set_host_status {
	my ($self, $id, $status) = @_;
	print "host: $id done: $status\n";
	my $sth = $self->{dbh}->prepare("update hosts set status=? where id=?");
	$sth->execute($status, $id);
}

sub get_unvisited_hostids {
	my $self = shift;
	my $max = shift;
	my @expressions;
	foreach (@_) {
		push @expressions, " and id <> ?";
	}
	my $sth = $self->{dbh}->prepare("select id from hosts where status=0" . join("", @expressions) . " LIMIT ?");
	$sth->execute(@_, $max);
	my @res;
	while (my $id = $sth->fetchrow()) {
   		push @res, $id;
	}
	return @res;
}

sub add_endpoint {
	my ($self, $hostid, $type, $path, $status) = @_;
	$self->{prepared}->{add_endpoint}->execute($hostid, $type, $path, $status);
	return $self->{dbh}->last_insert_id();
}

sub set_endpoint_status {
	my ($self, $id, $status) = @_;
	my $sth = $self->{dbh}->prepare("update endpoints set status=? where id=?");
	$sth->execute($status, $id);
}

sub get_endpoints_where_status {
	my ($self, $hostid, $status) = @_;
	my $sth = $self->{dbh}->prepare("select * from endpoints where hostid=? and status=?");
	$sth->execute($hostid, $status);
	return $sth->fetchall_arrayref();
}

sub get_endpoints_from_host {
	my ($self, $hostid) = @_;
	my $sth = $self->{dbh}->prepare("select * from endpoints where hostid=?");
	$sth->execute($hostid);
	return $sth->fetchall_arrayref();
}

sub increment_reference {
	my ($self, $from_host, $from_port, $to_host, $to_port) = @_;
	$self->{dbh}->do("UPDATE refs SET count = count + 1 WHERE pair=?; IF changes() = 0 THEN INSERT INTO refs (pair, count) VALUES (?, ?) END;", undef, "$from_host:$from_port->$to_host:$to_port", "$from_host:$from_port->$to_host:$to_port", 1);
}

1;