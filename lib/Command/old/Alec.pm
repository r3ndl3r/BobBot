package Command::Alec;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_alec);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Alec' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Make the bot say something good.' );
has pattern             => ( is => 'ro', default => '^alec' );
has function            => ( is => 'ro', default => sub { \&cmd_alec } );
has usage               => ( is => 'ro', default => '');

sub cmd_alec
{
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    $discord->send_message($channel, "Alec has coomvid. Stay away from him.");
    $discord->send_image($channel, {'content' => 'alec.gif:', 'name' => 'alec.gif', 'path' => "lib/Command/images/alec.gif"});
    $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
}

1;
