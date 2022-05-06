package Component::DBI;
use strict;
use warnings;
use Storable qw(freeze thaw);
use DBI;

use Exporter qw(import);

our @EXPORT = qw( get set );


sub new {
    my $class = shift;
    my $self  = {};
    my %attr  = ( PrintError => 0, RaiseError => 1 );
    my %auth;

    open AUTH, "/home/rendler/.dbi.auth" or die $!;

    while (<AUTH>) {
        chomp;
        s/\s//g;
        my ($key, $value) = split /=/, $_;
        if ($key =~ /^user(name)?$/i) {
            $auth{dbUser} = $value;
        } elsif ($key =~ /^pass(word)?$/i) {
            $auth{dbPass} = $value;
        }
    }

    $self->{'dsn'} = "DBI:MariaDB:bobbot";
    $self->{'dbh'} = DBI->connect($self->{'dsn'}, $auth{dbUser}, $auth{dbPass}, \%attr) or die $!;

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
