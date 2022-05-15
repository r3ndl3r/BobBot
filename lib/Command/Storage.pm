package Command::Storage;
use feature 'say';

use Moo;
use strictures 2;

use namespace::clean;
use Component::DBI;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_storage);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Storage' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Storage' );
has pattern             => ( is => 'ro', default => '^storage ?' );
has function            => ( is => 'ro', default => sub { \&cmd_storage } );
has usage               => ( is => 'ro', default => <<EOF
Storage
EOF
);

sub cmd_storage {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    my $db = Component::DBI->new();

    if ($args =~ /^init\s+(\S+)/i) {
        $db->set($1, {});
        $discord->send_message($channel, "Storage: init '$1'.");

        return;
    }
    
    if ($args =~ /^show\s+(\S+)/i) {
        if (! $db->get($1) ) {
            $discord->send_message($channel, "Storage: '$1' does not exist.");
            return;
        }

        print Data::Dumper::Dumper(\$db->get($1));
    }    
}

    

1;
