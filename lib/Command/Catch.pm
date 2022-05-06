package Command::Catch;

use feature 'say';
use utf8;
use Moo;
use strictures 2;
use namespace::clean;


use Exporter qw(import);
use Component::DBI;
our @EXPORT_OK = qw(cmd_catch);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => '' );
has access              => ( is => 'ro', default => 0 );
has usage               => ( is => 'ro', default => '' );
has description         => ( is => 'ro', default => '' );
has pattern             => ( is => 'ro', default => '' );
has function            => ( is => 'ro', default => sub {} );

has on_message => ( is => 'ro', default => sub {
    my $self = shift;
    $self->discord->gw->on('MESSAGE_CREATE' => sub {

    my ($gw, $hash) = @_;
        if (!(exists $hash->{'author'}{'bot'} and $hash->{'author'}{'bot'})) {
            cmd_catch($self, $hash);

        }
    })
});

sub cmd_catch {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $content = $msg->{'content'};
    my $replyto = '<@' . $author->{'id'} . '>';
    my $discord = $self->discord;
    my $db      = Component::DBI->new();

    my %catch = %{ $db->get('catch') };



    my @patterns = (
        [ 'wtf', 'Yeah! WHAT THE FUCK?!?' ],

        [ 'alec', $replyto . 'Yeah I agree, Alec is a beautiful man.' ],

        [ 'genshin', 'Genshin Impact is a game for n00bs.' ],

        [ 'vu21991-at3', "VU21991 AT3 resources zip:\nhttps://www.rendler.org/VU21991_-_AT3.zip", 1 ],
        [ 'ats.xlsx', "ATs excel sheet:\nhttps://www.rendler.org/ATs.xlsx", 1 ],

        [ 'shit', [ 
            $replyto . ' I shit on you.',
            $replyto . ' do you want to shit in my mouth?',
            $replyto . ' do you me to shit in your mouth?',
            ] ],
        
        [ 'fuck', [
            'No, fuck you!',
            'BIG FUCK!'
            ] ],

        [ '^(hi|hello)$', [
            'Hallo ' . $replyto,
            'Yoyoyoyo ' . $replyto
            ] ],

        [ 'hadi', [
            'HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI HADI',
            'Hadi likes anime girls.'
            ] ],

        [ 'omg', [
            'Bob is God.',
            'God is Bob.'
            ] ],

    );

    for (@patterns) {
        my ($pattern, $msg, $ignore) = @{ $_ };

        if ($content =~ /$pattern/i) {
            
            # If the $ignore value is set ignore the 5 min timeout for responding again.
            if (exists $catch{$author->{'id'}} &&
                    (time() - $catch{$author->{'id'}}) < 300 && 
                         !$ignore) {
                return;
            }
    
            $catch{$author->{'id'}} = time;
            $db->set('catch', \%catch);
        
            if (ref $msg eq 'ARRAY') {
                $msg = $msg->[rand @{ $msg }];
            }

            $discord->send_message($channel, $msg);
        }
    }
}
1;
