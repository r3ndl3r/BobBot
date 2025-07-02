package Command::Test;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;
use Data::Dumper;
use Component::DBI;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_test);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Test' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => '' );
has pattern             => ( is => 'ro', default => '^test ?' );
has function            => ( is => 'ro', default => sub { \&cmd_test } );
has usage               => ( is => 'ro', default => '' );


# has on_message => ( is => 'ro', default =>
#     sub {
#         my $self = shift;
#         $self->discord->gw->on('INTERACTION_CREATE' =>     
#             sub {
#                     my ($gw, $msg) = @_;

#                     my $id     = $msg->{'id'};
#                     my $token  = $msg->{'token'};
#                     my $data   = $msg->{'data'};
#                     my $custom = $data->{'custom_id'};
                    
#                     if (my ($say) = $custom =~ /say\.(.+)/) {
#                         $self->discord->delete_message($msg->{'channel_id'}, $msg->{'message'}{'id'});
#                         $self->discord->interaction_response($id, $token, $data->{'custom_id'}, "OK", sub { $self->discord->send_message($msg->{'channel_id'}, $say) });
#                     }
#                 }    
#         )
#     }
# );


sub cmd_test
{
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $msgid   = $msg->{'id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    
    my $db = Component::DBI->new();
    my $test = $db->get('test') || {};
    $test->{moo} = "mooo";
    #$test->{bob} = 12345;
    $db->set('test', $test);

    print Dumper $test, "\n";

    $discord->send_message($channel, $test->{moo});

    $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
}

1;
