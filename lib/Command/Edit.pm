package Command::Edit;
use feature 'say';
use utf8;

use Moo;
use strictures 2;

use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_edit);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'e' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'e' );
has pattern             => ( is => 'ro', default => '^edit ?' );
has function            => ( is => 'ro', default => sub { \&cmd_edit } );
has usage               => ( is => 'ro', default => <<EOF
###
EOF
);

sub cmd_edit {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    
    if (my ($modifyID, $newMSG) = $args =~ /^(\d{18})\s+(.*)/) {
        $discord->get_message($channel, $modifyID,
            sub {
                    my $msg = shift;
                    $msg->{'content'} = $msg->{'content'} . "\n\n" . $newMSG;
                    $discord->edit_message($channel, $modifyID, $msg);

            }
        );

    }

    $discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
}

1;
