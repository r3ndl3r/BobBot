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

                ;
            }
        ) 
    }
);


has on_message => ( is => 'ro', default =>
    sub {
        my $self = shift;
        $self->discord->gw->on('INTERACTION_CREATE' =>     
            sub {
                my ($gw, $msg) = @_;

                my $id    = $msg->{'id'};
                my $token = $msg->{'token'};
                my $data  = $msg->{'data'};

                if ($data->{'custom_id'} eq 'delete.all') {
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
                my %delete;

                for my $msg (@messages) {
                                                                # #oz
                    if ( ($args && $args eq 'all') || $channel eq 972066662868213820) {
                        $delete{$msg->{'id'}} = $msg->{'channel_id'};

                    } elsif ($args && $args eq 'me' && $msg->{'author'}{'id'} eq $author->{'id'}) {
                        $delete{$msg->{'id'}} = $msg->{'channel_id'};

                    } else {
                        # Bot
                        if ($msg->{'author'}{'id'} eq 955818369477640232) {
                            $delete{$msg->{'id'}} = $msg->{'channel_id'};
                        }
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
