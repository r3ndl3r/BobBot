package Command::Eval;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Data::Dumper;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_eval);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'Eval' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Make the bot do something.' );
has pattern             => ( is => 'ro', default => '^eval ?' );
has function            => ( is => 'ro', default => sub { \&cmd_eval } );
has usage               => ( is => 'ro', default => 'Usage: !eval <perl code>' );


sub cmd_eval {
    my ($self, $msg) = @_;

    my $pattern = $self->pattern;
    my $discord = $self->discord;
    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;
    my $replyto = '<@' . $author->{'id'} . '>';
    
    $discord->send_message($channel, eval $args);
    $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
}

1;
