package Command::Dump;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;
use Component::DBI;
use Data::Dumper;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_test);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Data Dumper' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => '' );
has pattern             => ( is => 'ro', default => '^dump ?' );
has function            => ( is => 'ro', default => sub { \&cmd_dump } );
has usage               => ( is => 'ro', default => '' );

sub cmd_dump {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = lc $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;
    my @args = split /\s+/, $args;

    my $discord = $self->discord;

    my $db = Component::DBI->new();
    my $dump = $db->get($args[0]);

    $discord->send_message($channel, Dumper($dump));
}

1;
