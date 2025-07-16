package Component::DBI;
use strict;
use warnings;
use Storable qw(freeze thaw);
use Config::Tiny;
use DBI;

use Exporter qw(import);

our @EXPORT = qw( get set del );


sub new {
    my $class  = shift;
    my $self   = {};
    my %attr   = ( PrintError => 0, RaiseError => 1 );
    my $config = Config::Tiny->read('config.ini', 'utf8');

    $self->{'dsn'} = "DBI:$config->{'db'}{'type'}:$config->{'db'}{'database'}";
    $self->{'dbh'} = DBI->connect($self->{'dsn'}, $config->{'db'}{'username'}, $config->{'db'}{'password'}, \%attr) or die $!;

    bless ($self, $class);

    return $self;
}


sub get {
    my ($self, $key) = @_;
    my $dbh = $self->{'dbh'};

    if (ifExist($self, $key)) {
        my $sql = "SELECT data FROM storage WHERE name = ?";
        my $sth = $dbh->prepare($sql);
        $sth->execute($key);
        my $thaw = thaw($sth->fetchrow_array());

        return $thaw;
    } else {
        return undef;
    }
} 


sub set {
    my ($self, $key, $data) = @_;
    my $dbh = $self->{'dbh'};

    # Check to see if storage key exists first.
    if (ifExist($self, $key)) {
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
    my $dbh = $self->{'dbh'};

    # Check to see if storage key exists first.
    if (ifExist($self, $key)) {
        my $sql = "DELETE FROM storage WHERE name = ?";
        my $sth = $dbh->prepare($sql);

        # Execute the delete statement and return success/failure.
        return $sth->execute($key) ? 1 : undef;
    } else {
        return undef;
    }
}


sub ifExist {
    my ($self, $key) = @_;
    my $dbh = $self->{'dbh'};

    my $sql = "SELECT data FROM bobbot.storage WHERE name = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($key);

    return $sth->fetchrow_array() ? 1 : undef;
}


sub dbh { 
    my $self = shift;
    my $dbh = $self->{'dbh'};

    return $dbh;
}

1;
