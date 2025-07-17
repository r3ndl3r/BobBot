package Command::Copy;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_copy);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Copy' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Copy' );
has pattern             => ( is => 'ro', default => '^copy ?' );
has function            => ( is => 'ro', default => sub { \&cmd_copy } );
has usage               => ( is => 'ro', default => <<EOF
###
EOF
);

sub cmd_copy {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;
    
    if (my ($msgid, $rchannel) = $args =~ /^(\d{18})\s+(\d{18})$/) {
        $discord->get_message($channel, $msgid,
            sub {
                my $msg = shift;
                $discord->send_message($rchannel, $msg);
            }
        );
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
    }
}
1;
