package Command::DeleteAll;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_deleteall);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'DeleteAll' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Delete all messages in a channel.' );
has pattern             => ( is => 'ro', default => '^deleteall' );
has function            => ( is => 'ro', default => sub { \&cmd_deleteall } );
has usage               => ( is => 'ro', default => '!deleteall' );

sub cmd_deleteall {
    my ($self, $msg) = @_;

    my $channel_id = $msg->{'channel_id'};

    my $messages = $self->discord->get_channel_messages($channel_id,
        sub {
            my $messages = shift;
            my @message_ids = map { $_->{'id'} } @$messages;
            $self->discord->bulk_delete_message($channel_id, \@message_ids);
        }
    );

    # Delete the !deleteall command.
    $self->discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
}

1;
