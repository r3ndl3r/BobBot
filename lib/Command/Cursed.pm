package Command::Cursed;
use feature 'say';

use Moo;
use strictures 2;
use namespace::clean;
use LWP::UserAgent;
use JSON;
use Component::DBI;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_cursed);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Cursed' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Rando cursed shit' );
has pattern             => ( is => 'ro', default => '^cursed ?' );
has function            => ( is => 'ro', default => sub { \&cmd_cursed } );
has usage               => ( is => 'ro', default => <<EOF
Usage: !cursed
EOF
);

sub cmd_cursed {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
    my $discord = $self->discord;
    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $url = "https://www.reddit.com/r/cursedimages.json?sort=top&t=week&limit=100";
    my $res = LWP::UserAgent->new->get($url);
    my $db = Component::DBI->new();

    my $json = from_json($res->decoded_content);
    my $cursed;
    my %cursed = %{ $db->get('cursed') };
    for (1 .. 100) {
        my $rand = int ( rand(49)) + 2;
        $cursed = $json->{data}{children}[$rand]{data}{url};
        next if exists $cursed{$cursed};

        $cursed{$cursed} = 1;
        last;
    }
    $db->set('cursed', \%cursed);

    $discord->send_message($channel, $cursed);
}

1;
