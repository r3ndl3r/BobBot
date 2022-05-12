package Command::Yahya;

use feature 'say';
use Moo;
use strictures 2;
use namespace::clean;
use Exporter qw(import);
our @EXPORT_OK = qw(cmd_yahya);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has some_random         => ( is => 'lazy', builder => sub { shift->bot->some_random } );

has name                => ( is => 'ro', default => 'Yahya' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Make the bot say something good' );
has pattern             => ( is => 'ro', default => '^yahya' );
has function            => ( is => 'ro', default => sub { \&cmd_yahya } );
has usage               => ( is => 'ro', default => '');

sub cmd_yahya {

    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    if ($args =~ /(with|and) his girlfriend/) {
        $discord->send_image($channel, {'content' => 'Forbidden Love.', 'name' => 'mac.png', 'path' => "lib/Command/images/mac.png"});
    } else {
        $discord->send_image($channel, {'content' => 'The genius behind Apple.', 'name' => 'apple.jpg', 'path' => "lib/Command/images/apple.jpg"});
    }

}

1;
