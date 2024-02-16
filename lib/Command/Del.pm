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
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    if ($args =~ /^\d+$/) {
        $discord->delete_message($msg->{'channel_id'}, $args);

    } else {
        my $messages = $discord->get_channel_messages($channel,
            sub {
                my $db       = Component::DBI->new();
                my @messages = @{ $_[0] };
                my %delete   = %{ $db->get('delete') };

                if ($args && $args eq 'me') {
                    my @msgs = map { $_->{'author'}{'id'} eq $author->{'id'} ? $_->{'id'} : () } @messages;

                    for my $id (@msgs) {
                        $discord->delete_message($channel, $id);
                        Mojo::IOLoop->timer(5, sub {});  # Delay of 1 second
                    }

                }

                # All messages or #oz
                if (($args && $args eq 'all') || $channel eq 972066662868213820) {
                    my @msgs = map { $_->{'id'} } @messages;

                    for my $id (@msgs) {
                        $discord->delete_message($channel, $id);
                        Mojo::IOLoop->timer(1, sub {});  # Delay of 1 second
                    }

                }

                #         # Bot
                #         if ($msg->{'author'}{'id'} eq 955818369477640232) {
                #             $delete{$msg->{'id'}} = $msg->{'channel_id'};
                #         }
                #     }
                # }

                # $db->set('delete', \%delete);
            }
        );
    }

    # Delete the !del command.
    $discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
}

sub delete_message_with_rate_limit {
    my ($self, $channel, $msg_id) = @_;

    my $route = "DELETE /channels/$channel/messages/$msg_id";
    if ( my $delay = $self->_rate_limited($route) ) {
        $self->log->warn('[Command::Del] Route is rate limited. Trying again in ' . $delay . ' seconds');
        Mojo::IOLoop->timer($delay => sub { $self->delete_message_with_rate_limit($channel, $msg_id) });
    } else {
        $self->discord->delete_message($channel, $msg_id);
    }
}

sub _rate_limited {
    my ($self, $route) = @_;

    # Implement your rate limiting logic here
    # For example, you could check a rate limit counter for the given route

    return 0;  # Return 0 if not rate limited, or the number of seconds to wait before retry
}

sub cmd_del_orig {
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
