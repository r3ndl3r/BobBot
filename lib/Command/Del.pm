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
has name                => ( is => 'ro', default => 'Delete' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Delete messages.' );
has pattern             => ( is => 'ro', default => '^del ?' );
has function            => ( is => 'ro', default => sub { \&cmd_del } );
has usage               => ( is => 'ro', default => '!delete [ids]' );


has timer_sub => ( is => 'ro', default =>
    sub { 
        my $self = shift;
        Mojo::IOLoop->recurring( 3 =>
        sub {
                my $db = Component::DBI->new();
                my %delete = %{ $db->get('delete') };

                for my $msg (sort keys %delete) {
                    $self->discord->delete_message($delete{$msg}, $msg);
                    my $n = scalar keys %delete;
                    print "DEL: $delete{$msg} - $msg [$n]\n";
                    delete $delete{$msg};
                    $db->set('delete', \%delete);
                    return;
                }
            }
        ) 
    }
);


has on_message => ( is => 'ro', default =>
    sub {
        my $self   = shift;
        my $config = $self->{'bot'}{'config'}{'oz'};
        
        $self->discord->gw->on('INTERACTION_CREATE' =>     
            sub {
                my ($gw, $msg) = @_;
                

                my $id    = $msg->{'id'};
                my $token = $msg->{'token'};
                my $data  = $msg->{'data'};

                if ($data->{'custom_id'} eq 'delete.all' && $msg->{'channel_id'} eq $config->{'channel'}) {
                    $msg->{'content'} = 'all';
                    $self->discord->interaction_response($id, $token, $data->{'custom_id'}, "DELETING PLEASE WAIT...", sub { cmd_del($self, $msg) });
                }    
            }
        )
    }
);


sub cmd_del {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $channel = $msg->{'channel_id'};
    my $args    = $msg->{'content'};

    # Remove the command prefix and whitespace from the arguments
    $args =~ s/^${\$self->pattern}\s*//i;

    if ($args eq 'all') {
        my $messages = $discord->get_channel_messages($channel,
            sub {
                my $messages = shift;

                # Extract message IDs from the messages
                my @msg_ids = map { $_->{'id'} } @$messages;

                # Delete all messages in the channel in batches of 100
                while (@msg_ids) {
                    my @batch = splice @msg_ids, 0, 100;
                    $discord->bulk_delete_message($channel, \@batch);

                    # Delay between batches to avoid rate limiting
                    sleep(1);
                }
            }
        );
    }

    # Delete the !del command
    $discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
}


1;
