package Command::Paste;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Storable qw(thaw);

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_paste);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'Paste' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Paste' );
has pattern             => ( is => 'ro', default => '^paste ?' );
has function            => ( is => 'ro', default => sub { \&cmd_paste } );
has usage               => ( is => 'ro', default => '!paste <msgID' );


sub cmd_paste {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    if (my ($id) = $args =~ /^(\d+)$/) {        
        my $sql = "SELECT content FROM messages WHERE id = ?";
        my $sth = $self->db->dbh->prepare($sql);
        $sth->execute($id);

        my $content = $sth->fetchrow_array();
        if ($content) {
            my $thaw = thaw($content);
            $discord->send_message($channel, $thaw);
            $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
        }
    }
}

1;
