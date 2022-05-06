package Command::###;
use feature 'say';

use Moo;
use strictures 2;

use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_###);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => '###' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => '###' );
has pattern             => ( is => 'ro', default => '^### ?' );
has function            => ( is => 'ro', default => sub { \&cmd_### } );
has usage               => ( is => 'ro', default => <<EOF
###
EOF
);

sub cmd_template {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;
    

1;
