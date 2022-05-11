package Command::Hadi;

use feature 'say';
use Moo;
use strictures 2;
use namespace::clean;
use Exporter qw(import);
our @EXPORT_OK = qw(cmd_hadi);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has some_random         => ( is => 'lazy', builder => sub { shift->bot->some_random } );

has name                => ( is => 'ro', default => 'Hadi' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Make the bot say something good' );
has pattern             => ( is => 'ro', default => '^hadi' );
has function            => ( is => 'ro', default => sub { \&cmd_hadi } );
has usage               => ( is => 'ro', default => '');

sub cmd_hadi {

    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    if ($args =~ /and his girlfriend/i) {
        $self->some_random->animu('hug')->then(sub {
            my $json = shift;
            my $wink = $json->{'image'};
            $self->discord->send_message($channel, $wink);
        })->catch(sub{
            $self->discord->send_message($channel, ":x: Sorry, couldn't find any animu. Try again later!");
        });
    } elsif ($args =~ /with his girlfriend/i) {
        $discord->send_image($channel, {'content' => '', 'name' => 'gf.png', 'path' => "lib/Command/images/gf.png"});
    } else {
        $discord->send_message($channel, "Hadi likes anime girls. Fact.");
    }

}

1;
