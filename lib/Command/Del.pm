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

has timer_sub           => ( is => 'ro',    default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( 3 =>
        sub {
                my $db = Component::DBI->new();
                my %delete = %{ $db->get('delete') };

                for my $msg (sort keys %delete) {
                    $self->discord->delete_message($delete{$msg}, $msg);
                    print "DELETE: $delete{$msg} - $msg\n";
                    delete $delete{$msg};
                    $db->set('delete', \%delete);
                    return;
                }

                ;
            }
        ) 
    }
);

sub cmd_del {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;

    if ($args) {
        $discord->delete_message($msg->{'channel_id'}, $args);
    
    } else {
        my $messages = $discord->get_channel_messages($channel,
            sub {
                my $db       = Component::DBI->new();
                my @messages = @{ $_[0] };
                my %delete;

                for my $msg (@messages) {
                    $delete{$msg->{'id'}} = $msg->{'channel_id'};
                    if ($msg->{'author'}{'id'} eq 955818369477640232) {
                        
                    }
                }
                $db->set('delete', \%delete);

            }
        );
    }

    # Delete the !del command.
    $discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
}

1;
