package Command::Fun;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_fun);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Fun' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Fun? I think not.' );
has pattern             => ( is => 'ro', default => '^fun ?' );
has function            => ( is => 'ro', default => sub { \&cmd_fun } );
has usage               => ( is => 'ro', default => '');

sub cmd_fun {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $db = Component::DBI->new();
    
    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    $discord->send_image($channel, {'content' => '', 'name' => 'fun.png', 'path' => "lib/Command/images/fun.jpg"});
    $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
}

1;
