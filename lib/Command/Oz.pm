package Command::Oz;
use feature 'say';

use Moo;
use strictures 2;
use XML::Simple;
use LWP::UserAgent;
use Component::DBI;

use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_oz);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'oz' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'oz' );
has pattern             => ( is => 'ro', default => '^oz ?' );
has function            => ( is => 'ro', default => sub { \&cmd_oz } );
has usage               => ( is => 'ro', default => '' );
has timer_seconds       => ( is => 'ro', default => 600 );

has timer_sub => ( is => 'ro', default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->cmd_oz } ) 
    }
);


has on_message => ( is => 'ro', default => 
    sub {
        my $self = shift;
        my $config = $self->{'bot'}{'config'}{'oz'};

        $self->discord->gw->on('MESSAGE_CREATE' =>
            sub {
                    my ($s, $m) = @_;
                    if ($config->{'channel'} eq $m->{'channel_id'} && $m->{'content'} eq 'del') {
                        cmd_oz($self, $m);
                    }


                }
        );
    }
);


sub cmd_oz {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i if $args;

    my $config = $self->{'bot'}{'config'}{'oz'};

    my ($sql, $sth);
    my $db  = Component::DBI->new();
    my $dbh = $db->{'dbh'};

    if ($args && $args eq 'del') {
        $discord->delete_message($channel, $msg->{'id'});
        $sql = "SELECT channel FROM oz WHERE channel IS NOT NULL";
        $sth = $dbh->prepare($sql);
        $sth->execute();

        my @messages;
        while (my $m = $sth->fetchrow_array()) {
            push @messages, $m;
        }

        for my $msg (@messages) {
            $discord->delete_message($config->{'channel'}, $msg);
            $sql = "UPDATE oz SET channel = NULL WHERE channel = ?";
            $sth = $dbh->prepare($sql);
            $sth->execute($msg);
        }

        return;
    }

    
    my $ua = LWP::UserAgent->new();
       $ua->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.54 Safari/537.36');

    my $res = $ua->get($config->{'url'});
    my $xml = XMLin($res->content);

    my @items = @{ $xml->{'channel'}{'item'} };

    for my $item (@items) {
        $sql = "SELECT link FROM oz WHERE link = ?";
        $sth = $dbh->prepare($sql);
        $sth->execute($item->{'link'});

        if ($sth->fetchrow_array()) {
            next;
        }

        $discord->send_message($config->{'channel'}, $item->{'link'},
            sub {
                my $id = shift->{'id'};
                my $sql = "INSERT INTO oz (link, channel) VALUES(?, ?)";
                my $sth = $dbh->prepare($sql);

                $sth->execute($item->{'link'}, $id);
            } 
        );

    }
    

}    

1;
