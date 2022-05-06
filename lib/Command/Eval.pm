package Command::Eval;
use feature 'say';

use Moo;
use strictures 2;
use namespace::clean;
use Component::DBI;
use Data::Dumper;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_eval);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Eval' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Make the bot do something.' );
has pattern             => ( is => 'ro', default => '^eval ?' );
has function            => ( is => 'ro', default => sub { \&cmd_eval } );
has usage               => ( is => 'ro', default => <<EOF
Usage: !eval <perl commands>
EOF
);

sub cmd_eval {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $db = Component::DBI->new();
    
    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    $discord->send_message($channel, eval $args);
}

1;
