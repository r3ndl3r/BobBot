package Command::Del;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_del);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Del' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Delete messages.' );
has pattern             => ( is => 'ro', default => '^del ?' );
has function            => ( is => 'ro', default => sub { \&cmd_del } );
has usage               => ( is => 'ro', default => '!delete [ids]' );

sub cmd_del {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;

    my @msgs = split /\s+/, $args;
    for (@msgs) {
        $discord->delete_message($channel, $_);
    }
}

1;
