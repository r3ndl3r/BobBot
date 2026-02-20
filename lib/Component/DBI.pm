package Component::DBI;
use strict;
use warnings;
use Storable qw(freeze thaw);
use Config::Tiny;
use DBI;

use Exporter qw(import);

our @EXPORT = qw( get set del );

sub new {
    my ($class, %args) = @_;
    
    my ($authDbUser, $authDbPass, $db_host);
    
    if ($ENV{DB_USER} && $ENV{DB_PASS}) {
        $authDbUser = $ENV{DB_USER};
        $authDbPass = $ENV{DB_PASS};
        $db_host = $ENV{DB_HOST} || 'localhost';
        print "Using environment variables for DB connection\n" if $ENV{DEBUG};
    } else {
        die "Database credentials not found. Set DB_USER/DB_PASS environment variables.";
    }
    
    my $db_name = $ENV{DB_NAME} || 'bobbot';
    my $db_port = $ENV{DB_PORT} || '3306';
    
    # FIXED: Handle localhost port restriction
    my $dsn;
    if ($db_host eq 'localhost' && $db_port eq '3306') {
        # For localhost with default port, don't specify port at all
        $dsn = "DBI:MariaDB:database=$db_name;host=$db_host";
    } elsif ($db_host eq 'localhost') {
        # For localhost with non-default port, use socket path or 127.0.0.1
        # Try using 127.0.0.1 instead of localhost to allow port specification
        $dsn = "DBI:MariaDB:database=$db_name;host=127.0.0.1;port=$db_port";
        print "Using 127.0.0.1 instead of localhost for custom port\n" if $ENV{DEBUG};
    } else {
        # For remote hosts, full specification works fine
        $dsn = "DBI:MariaDB:database=$db_name;host=$db_host;port=$db_port";
    }
    
    print "DSN: $dsn\n" if $ENV{DEBUG};
    
    my $self = bless {
        dsn => $dsn,
        dbUser => $authDbUser,
        dbPass => $authDbPass,
        %args
    }, $class;
    
    $self->connect();
    return $self;
}

sub connect {
    my ($self) = @_;
    
    $self->{dbh} = DBI->connect(
        $self->{dsn}, 
        $self->{dbUser}, 
        $self->{dbPass}, 
        { 
            PrintError => 0, 
            RaiseError => 1,
            AutoCommit => 1
        }
    ) or die "Database connection failed: " . $DBI::errstr;
    
    print "Database connected successfully\n" if $ENV{DEBUG};
}

sub ensure_connection {
    my ($self) = @_;
    
    eval { $self->{dbh}->do("SELECT 1"); };
    
    if ($@) {
        print "Database connection lost, reconnecting...\n" if $ENV{DEBUG};
        $self->connect();
    }
}

sub get {
    my ($self, $key) = @_;
    $self->ensure_connection();
    my $dbh = $self->{'dbh'};

    if ($self->ifExist($key)) {
        my $sql = "SELECT data FROM storage WHERE name = ?";
        my $sth = $dbh->prepare($sql);
        $sth->execute($key);
        my $frozen_data = $sth->fetchrow_array();
        my $thaw = thaw($frozen_data);

        return $thaw;
    } else {
        return undef;
    }
} 

sub set {
    my ($self, $key, $data) = @_;
    $self->ensure_connection();
    my $dbh = $self->{'dbh'};

    if ($self->ifExist($key)) {
        my $sql = "UPDATE storage SET data = ? WHERE name = ?";
        my $sth = $dbh->prepare($sql);

        return $sth->execute(freeze($data), $key) ? 1 : undef;
    } else {
        my $sql = "INSERT INTO storage (name, data) VALUES(?, ?)";
        my $sth = $dbh->prepare($sql);

        return $sth->execute($key, freeze($data)) ? 1 : undef;
    }
}

sub del {
    my ($self, $key, $data) = @_;
    $self->ensure_connection();
    my $dbh = $self->{'dbh'};

    if ($self->ifExist($key)) {
        my $sql = "DELETE FROM storage WHERE name = ?";
        my $sth = $dbh->prepare($sql);

        return $sth->execute($key) ? 1 : undef;
    } else {
        return undef;
    }
}

sub ifExist {
    my ($self, $key) = @_;
    $self->ensure_connection();
    my $dbh = $self->{'dbh'};

    my $db_name = $ENV{DB_NAME} || 'bobbot';
    my $sql = "SELECT data FROM $db_name.storage WHERE name = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($key);

    return $sth->fetchrow_array() ? 1 : undef;
}

sub dbh { 
    my $self = shift;
    $self->ensure_connection();
    my $dbh = $self->{'dbh'};

    return $dbh;
}

sub DESTROY {
    my $self = shift;
    if ($self->{dbh}) {
        $self->{dbh}->disconnect();
        print "Database connection closed\n" if $ENV{DEBUG};
    }
}

1;
