package Command::Catch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Storable qw(freeze);

use Exporter qw(import);
use Component::DBI;
our @EXPORT_OK = qw(cmd_catch catch);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => '' );
has access              => ( is => 'ro', default => 0 );
has usage               => ( is => 'ro', default => '' );
has description         => ( is => 'ro', default => '' );
has pattern             => ( is => 'ro', default => '' );
has function            => ( is => 'ro', default => sub {} );

has on_message => ( is => 'ro', default =>

    sub {
        my $self = shift;
        $self->discord->gw->on('MESSAGE_CREATE' =>     
          
            sub {
                    my ($s, $m) = @_;
                    my $db  = Component::DBI->new();
                    my $dbh = $db->{'dbh'};

                    my $sql = "INSERT INTO messages (id, content) VALUES(?, ?)";
                    my $sth = $dbh->prepare($sql);

                    $sth->execute($m->{'id'}, freeze($m)) ;

                    if (!(exists $m->{'author'}{'bot'} and $m->{'author'}{'bot'})) {
                        cmd_catch($self, $m);
                    }
            }
        )
    }
);

sub cmd_catch {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $content = $msg->{'content'};
    my $replyto = '<@' . $author->{'id'} . '>';
    my $discord = $self->discord;
    my $db      = Component::DBI->new();

    my %catch = %{ $db->get('catch') };

    do "./Catch.pm";
    my @patterns = @Command::Catch::patterns;

    for (@patterns) {
        my ($pattern, $msg, $ignore) = @{ $_ };

        if ($content =~ /$pattern/i) {
            
            # If the $ignore value is set ignore the 5 min timeout for responding again.
            if (exists $catch{$author->{'id'}} &&
                    (time() - $catch{$author->{'id'}}) < 300 && 
                         !$ignore) {
                             
                return;
            }
    
            $catch{$author->{'id'}} = time;
            $db->set('catch', \%catch);
        
            if (ref $msg eq 'ARRAY') {
                $msg = $msg->[rand @{ $msg }];
            }

            $discord->send_message($channel, $msg);
        }
    }
}

1;
