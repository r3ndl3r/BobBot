# /home/rendler/Bobbot/lib/Bot/API.pm
package Bot::API;

use Moo;
use strictures 2;
use Mojolicious;
use Mojo::Server::Daemon;
use namespace::clean;

has bot    => ( is => 'ro', required => 1 );
has app    => ( is => 'lazy', builder => sub { 
    my $self = shift;
    my $app = Mojolicious->new;
    
    # Setup helpers for easy access to bot components in routes
    $app->helper(bot => sub { $self->bot });
    $app->helper(db  => sub { $self->bot->db });
    $app->helper(discord => sub { $self->bot->discord });
    
    # Default system routes
    my $routes = $app->routes;
    $routes->get('/status' => sub {
        my $c = shift;
        $c->render(json => {
            status  => 'online',
            uptime  => $c->bot->uptime,
            guilds  => $c->bot->session->{num_guilds} // 0,
            version => '1.0.0',
        });
    });

    # Send a Direct Message to a Discord User
    # Expects JSON: { "text": "message content" } OR { "embed": { ... } }
    $routes->post('/message/dm/:user_id' => sub {
        my $c = shift;
        my $user_id = $c->stash('user_id');
        my $json = $c->req->json;

        unless ($json && ($json->{text} || $json->{embed})) {
            return $c->render(json => { error => 'Missing "text" or "embed" field in JSON body' }, status => 400);
        }

        my $payload = $json->{embed} // $json->{text};

        # Use the bot's discord object to send the DM
        $c->discord->send_dm($user_id, $payload, sub {
            my $resp = shift;
            if ($resp && ref $resp eq 'HASH' && $resp->{id}) {
                $c->render(json => { success => 1, message_id => $resp->{id} });
            } else {
                $c->render(json => { success => 0, error => 'Failed to send DM. Check user ID and bot permissions.' }, status => 500);
            }
        });
    });

    return $app;
});

has daemon => ( is => 'rw' );

# Initialize and start the HTTP server
sub start {
    my $self = shift;
    my $api_config = $self->bot->config->{api};

    # Default to disabled if not explicitly enabled in config
    unless ($api_config && $api_config->{enabled}) {
        $self->bot->log->info("[API] HTTP server is disabled in config.");
        return;
    }

    my $port   = $api_config->{port}   // 3000;
    my $listen = $api_config->{listen} // '127.0.0.1';

    $self->daemon(Mojo::Server::Daemon->new(
        app    => $self->app,
        listen => ["http://$listen:$port"]
    ));

    $self->daemon->start;
    $self->bot->log->info("[API] HTTP server listening on http://$listen:$port");
}

# Proxy method to get the router for command registration
sub routes {
    my $self = shift;
    return $self->app->routes;
}

1;
