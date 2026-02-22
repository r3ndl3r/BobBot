# Bobbot API Documentation

Bobbot now includes a lightweight HTTP API server built on the **Mojolicious** ecosystem. This allows for two-way communication between external web applications and the bot's core logic, database, and Discord connection.

---

## 1. Architecture Overview

The API server runs within the same process and event loop as the Discord bot. This means:
*   **Zero Latency:** The API can directly interact with the bot's memory and objects.
*   **Shared Resources:** The API uses the same MariaDB instance and Mojolicious event loop.
*   **Asynchronous:** API requests do not block the bot's Discord gateway operations.

---

## 2. Configuration (`config.ini`)

The API is configured via the `[api]` section in your configuration file.

```ini
[api]
enabled = 1
port = 3000
# For security, bind to localhost only (127.0.0.1)
listen = 127.0.0.1
```

---

## 3. Base API Routes

These routes are built into the core `Bot::API` class.

### `GET /status`
Returns basic health and status information about the bot.
*   **Response:**
    ```json
    {
      "status": "online",
      "uptime": "1 hour 12 minutes",
      "guilds": 2,
      "version": "1.0.0"
    }
    ```

### `POST /message/dm/:user_id`
Sends a direct message to a Discord user.
*   **Request Body (JSON):**
    ```json
    {
      "text": "Your reminder is here!"
    }
    ```
    *OR a full Discord embed:*
    ```json
    {
      "embed": {
        "title": "Reminder",
        "description": "Don't forget the event!",
        "color": 3447003
      }
    }
    ```
*   **Response:**
    ```json
    {
      "success": 1,
      "message_id": "1391000000000000000"
    }
    ```

---

## 4. Extending the API (Command Modules)

Any Command module in `lib/Command/` can register its own API routes by implementing an `api_routes` method.

### How to Implement `api_routes`

In your module's `.pm` file, add the following sub:

```perl
sub api_routes {
    my ($self, $r) = @_; # $r is the Mojolicious::Routes object

    # Define your module-specific routes here
    $r->get('/twitch/settings' => sub {
        my $c = shift;
        # Use $self to access module logic or $c->db to access the database
        $c->render(json => $self->db->get('twitch_settings'));
    });

    $r->post('/twitch/update' => sub {
        my $c = shift;
        my $params = $c->req->json;
        $self->db->set('twitch_settings', $params);
        $c->render(json => { success => 1 });
    });
}
```

### Available Helpers in Routes
Within an API route callback, you have access to several convenience helpers:
*   `$c->bot`: The main `Bot::Bobbot` instance.
*   `$c->db`: The `Component::DBI` instance (shared database).
*   `$c->discord`: The `Mojo::Discord` instance for sending messages.

---

## 5. Security Note

Currently, security is handled via IP restriction. By binding to `127.0.0.1`, only applications running on the same server can access the API. If you need to expose this over a network, it is highly recommended to implement an `X-API-Key` check or use a reverse proxy with authentication.
