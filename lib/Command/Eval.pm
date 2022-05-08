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

# has timer_sub           => ( is => 'ro',    default => sub 
#     { 
#         my $self = shift;
#         Mojo::IOLoop->recurring( 5 =>
#         sub {
#                 my $db = Component::DBI->new();
#                 my %delete = %{ $db->get('delete') };

#                 for my $msg (sort keys %delete) {
#                     $self->discord->delete_message($delete{$msg}, $msg);
#                     print "DELETE: $msg\n";
#                     delete $delete{$msg};
#                     $db->set('delete', \%delete);
#                     return;
#                 }

#                 ;
#             }
#         ) 
#     }
# );

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

    
    # my $messages = $discord->get_channel_messages($channel,
    #     sub {
    #         my @messages = @{ $_[0] };
    #         my %delete;
    #         for my $msg (@messages) {
    #             if ($msg->{'author'}{'id'} eq 955818369477640232) {
    #                 $delete{$msg->{'id'}} = $msg->{'channel_id'};
    #             }
    #         }
    #         $db->set('delete', \%delete);

    #     }
    # );
    
    $discord->send_message($channel, eval $args);
}

1;
