# Spotify Connect Protocol Reference

A comprehensive reference for the Spotify Connect protocol, first written from librespot's
implementation. Spotifly now speaks it itself, in `Spotifly/SwiftLibrespot/` — the dealer
in `Dealer/`, the device state and remote commands in `Connect/SpircController.swift`.
Where this document and a capture from a real client disagree, the capture wins.

## Table of Contents

- [Overview](#overview)
- [WebSocket Endpoints](#websocket-endpoints)
- [Incoming Commands](#incoming-commands)
  - [Request Wrapper](#request-wrapper)
  - [Transfer](#transfer)
  - [Play](#play)
  - [Pause](#pause)
  - [Resume](#resume)
  - [SeekTo](#seekto)
  - [SkipNext](#skipnext)
  - [SkipPrev](#skipprev)
  - [SetShufflingContext](#setshufflingcontext)
  - [SetRepeatingContext](#setrepeatingcontext)
  - [SetRepeatingTrack](#setrepeatingtrack)
  - [AddToQueue](#addtoqueue)
  - [SetQueue](#setqueue)
  - [SetOptions](#setoptions)
  - [UpdateContext](#updatecontext)
- [Outgoing State Updates](#outgoing-state-updates)
  - [PutStateRequest](#putstaterequest)
  - [PutStateReason](#putstatereason)
- [Core Data Structures](#core-data-structures)
  - [PlayerState](#playerstate)
  - [ProvidedTrack](#providedtrack)
  - [Context](#context)
  - [ContextTrack](#contexttrack)
  - [ContextPage](#contextpage)
- [Cluster Updates](#cluster-updates)
  - [ClusterUpdate](#clusterupdate)
  - [ClusterUpdateReason](#clusterupdatereason)
- [Volume Commands](#volume-commands)
- [Session Updates](#session-updates)
- [Enumerations](#enumerations)
  - [DeviceType](#devicetype)
  - [MemberType](#membertype)
  - [Track Providers](#track-providers)
- [Restrictions](#restrictions)

---

## Overview

Spotify Connect uses a WebSocket-based dealer connection for real-time communication between devices. Messages are exchanged as protobuf-encoded payloads, often gzip-compressed and base64-encoded.

The protocol enables:
- **Remote control**: Control playback on any device from any other device
- **State synchronization**: Keep all devices in sync with the current playback state
- **Device discovery**: See all available devices in the user's account
- **Playback transfer**: Seamlessly move playback between devices

---

## WebSocket Endpoints

These are the dealer endpoints the client subscribes to for receiving events:

| Endpoint | Description | Payload Type |
|----------|-------------|--------------|
| `hm://pusher/v1/connections/` | Connection ID updates | String (in header `Spotify-Connection-Id`) |
| `hm://connect-state/v1/cluster` | Cluster state updates | [`ClusterUpdate`](#clusterupdate) |
| `hm://connect-state/v1/connect/volume` | Volume change requests | [`SetVolumeCommand`](#volume-commands) |
| `hm://connect-state/v1/connect/logout` | Logout requests | `LogoutCommand` |
| `hm://connect-state/v1/player/command` | Player commands (request/reply) | [`Request`](#request-wrapper) |
| `hm://playlist/v2/playlist/` | Playlist modification notifications | `PlaylistModificationInfo` |
| `social-connect/v2/session_update` | Social/Jam session updates | [`SessionUpdate`](#session-updates) |
| `spotify:user:attributes:update` | User attribute updates | `UserAttributesUpdate` |
| `spotify:user:attributes:mutated` | User attribute mutations | `UserAttributesMutation` |

---

## Incoming Commands

Commands received from other devices/clients to control playback are sent via `hm://connect-state/v1/player/command`.

### Request Wrapper

All commands are wrapped in a `Request` structure:

```
Request {
    message_id: u32              // Unique message identifier
    sent_by_device_id: string    // Device that sent the command
    command: Command             // The actual command (see below)
}
```

The `command` field contains one of the following command types, identified by the `endpoint` field in the JSON.

---

### Transfer

**Endpoint:** `transfer`

Transfers playback to this device, including full state restoration.

```
TransferCommand {
    data: TransferState              // Full state to restore
    options: TransferOptions         // How to restore
    from_device_identifier: string   // Source device
    logging_params: LoggingParams
}
```

#### TransferState

```
TransferState {
    options: ContextPlayerOptions {
        shuffling_context: bool
        repeating_context: bool
        repeating_track: bool
        playback_speed: float
    }
    playback: Playback {
        timestamp: int64
        position_as_of_timestamp: int32
        playback_speed: double
        is_paused: bool
        current_track: ContextTrack
    }
    current_session: Session {
        play_origin: PlayOrigin
        context: Context
        current_uid: string
        option_overrides: ContextPlayerOptionOverrides
        shuffle_seed: string
    }
    queue: Queue {
        tracks: [ContextTrack]
        is_playing_queue: bool
    }
    play_history: PlayHistory
}
```

#### TransferOptions

```
TransferOptions {
    restore_paused: string?      // "true" or "false"
    restore_position: string?    // "true" or "false"
    restore_track: string?       // "true" or "false"
    retain_session: string?      // "true" or "false"
}
```

---

### Play

**Endpoint:** `play`

Starts playback of a new context (playlist, album, artist, etc.).

```
PlayCommand {
    context: Context             // What to play
    play_origin: PlayOrigin      // Where the command originated
    options: PlayOptions         // How to start playback
    logging_params: LoggingParams
}
```

#### PlayOptions

```
PlayOptions {
    skip_to: SkipTo {
        track_uid: string?       // Skip to track by UID
        track_uri: string?       // Skip to track by URI
        track_index: u32?        // Skip to track by index
    }
    player_options_override: ContextPlayerOptionOverrides {
        shuffling_context: bool?
        repeating_context: bool?
        repeating_track: bool?
        playback_speed: float?
    }
    license: string?
    seek_to: u32?                // Start position in ms
    always_play_something: bool?
    audio_stream: string?
    initially_paused: bool?
    prefetch_level: string?
    system_initiated: bool?
}
```

#### PlayOrigin

```
PlayOrigin {
    feature_identifier: string   // e.g., "your_library", "browse", "playlist"
    feature_version: string
    view_uri: string
    external_referrer: string
    referrer_identifier: string
    device_identifier: string
    feature_classes: [string]
    restriction_identifier: string
}
```

See also: [`Context`](#context)

---

### Pause

**Endpoint:** `pause`

Pauses playback.

```
PauseCommand {
    logging_params: LoggingParams
}
```

---

### Resume

**Endpoint:** `resume`

Resumes playback.

```
GenericCommand {
    logging_params: LoggingParams
}
```

---

### SeekTo

**Endpoint:** `seek_to`

Seeks to a specific position in the current track.

```
SeekToCommand {
    value: u32           // Position in milliseconds
    position: u32        // Also position (legacy field)
    logging_params: LoggingParams
}
```

---

### SkipNext

**Endpoint:** `skip_next`

Skips to the next track, optionally to a specific track.

```
SkipNextCommand {
    track: ProvidedTrack?    // Optional: specific track to skip to
    logging_params: LoggingParams
}
```

See also: [`ProvidedTrack`](#providedtrack)

---

### SkipPrev

**Endpoint:** `skip_prev`

Skips to the previous track (or seeks to beginning if position > 3 seconds).

```
GenericCommand {
    logging_params: LoggingParams
}
```

---

### SetShufflingContext

**Endpoint:** `set_shuffling_context`

Toggles shuffle mode.

```
SetValueCommand {
    value: bool          // true = shuffle on, false = shuffle off
    logging_params: LoggingParams
}
```

---

### SetRepeatingContext

**Endpoint:** `set_repeating_context`

Toggles context repeat mode (repeat playlist/album).

```
SetValueCommand {
    value: bool          // true = repeat on, false = repeat off
    logging_params: LoggingParams
}
```

---

### SetRepeatingTrack

**Endpoint:** `set_repeating_track`

Toggles single track repeat mode.

```
SetValueCommand {
    value: bool          // true = repeat track, false = no repeat
    logging_params: LoggingParams
}
```

---

### AddToQueue

**Endpoint:** `add_to_queue`

Adds a track to the playback queue.

```
AddToQueueCommand {
    track: ProvidedTrack     // Track to add
    logging_params: LoggingParams
}
```

See also: [`ProvidedTrack`](#providedtrack)

---

### SetQueue

**Endpoint:** `set_queue`

Replaces the entire queue.

```
SetQueueCommand {
    next_tracks: [ProvidedTrack]   // Upcoming tracks
    prev_tracks: [ProvidedTrack]   // Previous tracks
    queue_revision: string         // Queue version identifier
    logging_params: LoggingParams
}
```

See also: [`ProvidedTrack`](#providedtrack)

---

### SetOptions

**Endpoint:** `set_options`

Sets multiple playback options at once.

```
SetOptionsCommand {
    shuffling_context: bool?
    repeating_context: bool?
    repeating_track: bool?
    options: OptionsOptions {
        only_for_local_device: bool
        override_restrictions: bool
        system_initiated: bool
    }
    logging_params: LoggingParams
}
```

---

### UpdateContext

**Endpoint:** `update_context`

Updates the current playback context (e.g., when a playlist is modified).

```
UpdateContextCommand {
    context: Context
    session_id: string?
}
```

See also: [`Context`](#context)

---

## Outgoing State Updates

The client sends state updates via HTTP PUT to:
```
PUT /connect-state/v1/devices/{device_id}
```

### PutStateRequest

```
PutStateRequest {
    callback_url: string
    device: Device {
        device_info: DeviceInfo
        player_state: PlayerState
        private_device_info: PrivateDeviceInfo {
            platform: string
        }
        transfer_data: bytes
    }
    member_type: MemberType
    is_active: bool
    put_state_reason: PutStateReason
    message_id: u32
    last_command_sent_by_device_id: string
    last_command_message_id: u32
    started_playing_at: u64
    has_been_playing_for_ms: u64
    client_side_timestamp: u64
    only_write_player_state: bool
}
```

#### DeviceInfo

```
DeviceInfo {
    can_play: bool
    volume: u32                          // 0-65535
    name: string                         // Device display name
    capabilities: Capabilities
    device_software_version: string
    device_type: DeviceType
    spirc_version: string
    device_id: string
    is_private_session: bool
    is_social_connect: bool
    client_id: string
    brand: string
    model: string
    metadata_map: map<string, string>
    product_id: string
    deduplication_id: string
    is_offline: bool
    public_ip: string
    license: string
    is_group: bool
    is_dynamic_device: bool
    disallow_playback_reasons: [string]
    disallow_transfer_reasons: [string]
    audio_output_device_info: AudioOutputDeviceInfo {
        audio_output_device_type: AudioOutputDeviceType
        device_name: string
    }
}
```

#### Capabilities

```
Capabilities {
    can_be_player: bool
    restrict_to_local: bool
    gaia_eq_connect_id: bool
    supports_logout: bool
    is_observable: bool
    volume_steps: int32                  // Number of volume steps
    supported_types: [string]            // ["audio/track", "audio/episode", ...]
    command_acks: bool
    supports_rename: bool
    hidden: bool
    disable_volume: bool
    connect_disabled: bool
    supports_playlist_v2: bool
    is_controllable: bool
    supports_external_episodes: bool
    supports_set_backend_metadata: bool
    supports_transfer_command: bool
    supports_command_request: bool
    is_voice_enabled: bool
    needs_full_player_state: bool
    supports_gzip_pushes: bool
    supports_set_options_command: bool
    supports_hifi: CapabilitySupportDetails
    supports_rooms: bool
    supports_dj: bool
    supported_audio_quality: AudioQuality
}
```

### PutStateReason

| Value | Description |
|-------|-------------|
| `UNKNOWN_PUT_STATE_REASON` | Unknown reason |
| `SPIRC_HELLO` | Initial hello/handshake |
| `SPIRC_NOTIFY` | General notification |
| `NEW_DEVICE` | Device just appeared |
| `PLAYER_STATE_CHANGED` | Playback state changed |
| `VOLUME_CHANGED` | Volume was adjusted |
| `PICKER_OPENED` | Device picker was opened |
| `BECAME_INACTIVE` | Device became inactive |
| `ALIAS_CHANGED` | Device alias changed |
| `NEW_CONNECTION` | New connection established |
| `PULL_PLAYBACK` | Pulling playback from another device |
| `AUDIO_DRIVER_INFO_CHANGED` | Audio output changed |
| `PUT_STATE_RATE_LIMITED` | Rate-limited state update |
| `BACKEND_METADATA_APPLIED` | Backend metadata was applied |

---

## Core Data Structures

### PlayerState

The central structure representing current playback state.

```
PlayerState {
    timestamp: int64                     // State timestamp
    context_uri: string                  // e.g., "spotify:playlist:xxx"
    context_url: string                  // Context URL
    context_restrictions: Restrictions
    play_origin: PlayOrigin
    index: ContextIndex {
        page: u32                        // Page index in context
        track: u32                       // Track index in page
    }
    track: ProvidedTrack                 // Currently playing track
    playback_id: string                  // Unique playback session ID
    playback_speed: double               // Playback speed multiplier
    position_as_of_timestamp: int64      // Position in ms at timestamp
    duration: int64                      // Track duration in ms
    is_playing: bool                     // Currently playing (not paused/stopped)
    is_paused: bool                      // Currently paused
    is_buffering: bool                   // Currently buffering
    is_system_initiated: bool            // Playback started by system
    options: ContextPlayerOptions {
        shuffling_context: bool
        repeating_context: bool
        repeating_track: bool
        playback_speed: float
        modes: map<string, string>
    }
    restrictions: Restrictions
    suppressions: Suppressions {
        providers: [string]
    }
    prev_tracks: [ProvidedTrack]         // Up to 10 previous tracks
    next_tracks: [ProvidedTrack]         // Up to 80 next tracks
    context_metadata: map<string, string>
    page_metadata: map<string, string>
    session_id: string                   // Session identifier
    queue_revision: string               // Queue version
    position: int64                      // Current position
    playback_quality: PlaybackQuality {
        bitrate_level: BitrateLevel      // low, normal, high, very_high, hifi
        strategy: BitrateStrategy
        target_bitrate_level: BitrateLevel
        hifi_status: HiFiStatus
    }
    signals: [string]
}
```

---

### ProvidedTrack

Represents a track in the playback queue or context.

```
ProvidedTrack {
    uri: string                          // e.g., "spotify:track:xxx"
    uid: string                          // Internal unique identifier
    metadata: map<string, string>        // Track metadata
    removed: [string]                    // Removed reasons
    blocked: [string]                    // Blocked reasons
    provider: string                     // "context", "queue", "autoplay"
    restrictions: Restrictions
    album_uri: string                    // Album URI
    disallow_reasons: [string]
    artist_uri: string                   // Artist URI
}
```

---

### Context

Represents a playback context (playlist, album, artist, etc.).

```
Context {
    uri: string                          // e.g., "spotify:playlist:xxx"
    url: string                          // Context URL for fetching
    metadata: map<string, string>
    restrictions: Restrictions
    pages: [ContextPage]                 // Pages of tracks
    loading: bool                        // Still loading
}
```

---

### ContextTrack

A track within a context (simpler than [`ProvidedTrack`](#providedtrack)).

```
ContextTrack {
    uri: string                          // e.g., "spotify:track:xxx"
    uid: string                          // Internal unique identifier
    gid: bytes                           // Spotify internal ID (binary)
    metadata: map<string, string>
}
```

---

### ContextPage

A page of tracks within a context (for pagination).

```
ContextPage {
    page_url: string                     // URL to fetch this page
    next_page_url: string                // URL to fetch next page
    metadata: map<string, string>
    tracks: [ContextTrack]               // Tracks in this page
    loading: bool                        // Still loading
}
```

---

## Cluster Updates

Received when any device in the cluster changes state.

### ClusterUpdate

```
ClusterUpdate {
    cluster: Cluster {
        changed_timestamp_ms: int64
        active_device_id: string         // Currently active device
        player_state: PlayerState        // Current playback state
        device: map<string, DeviceInfo>  // All devices in cluster
        transfer_data: bytes             // For transferring playback
        transfer_data_timestamp: u64
        need_full_player_state: bool
        server_timestamp_ms: int64
        needs_state_updates: bool
        started_playing_at_timestamp: u64
    }
    update_reason: ClusterUpdateReason
    ack_id: string
    devices_that_changed: [string]       // Device IDs that changed
}
```

### ClusterUpdateReason

| Value | Description |
|-------|-------------|
| `UNKNOWN_CLUSTER_UPDATE_REASON` | Unknown reason |
| `DEVICES_DISAPPEARED` | Device(s) went offline |
| `DEVICE_STATE_CHANGED` | Device playback state changed |
| `NEW_DEVICE_APPEARED` | New device came online |
| `DEVICE_VOLUME_CHANGED` | Volume changed on a device |
| `DEVICE_ALIAS_CHANGED` | Device name changed |
| `DEVICE_NEW_CONNECTION` | Device reconnected |

---

## Volume Commands

Volume is controlled separately from other commands.

```
SetVolumeCommand {
    volume: int32                        // 0-65535
    command_options: ConnectCommandOptions {
        message_id: int32
        target_alias_id: u32
    }
    logging_params: ConnectLoggingParams {
        interaction_ids: [string]
        page_instance_ids: [string]
    }
    connection_type: string
}
```

---

## Session Updates

For Social Connect / Jam features.

```
SessionUpdate {
    session: Session {
        timestamp: int64
        session_id: string
        join_session_token: string
        join_session_url: string
        join_session_uri: string
        session_owner_id: string
        session_members: [SessionMember {
            timestamp: int64
            id: string
            username: string
            display_name: string
            image_url: string
            large_image_url: string
            is_listening: bool
            is_controlling: bool
        }]
        is_session_owner: bool
        is_listening: bool
        is_controlling: bool
        is_discoverable: bool
        initial_session_type: SessionType
        host_active_device_id: string
    }
    reason: SessionUpdateReason
    updated_session_members: [SessionMember]
}
```

### SessionUpdateReason

| Value | Description |
|-------|-------------|
| `UNKNOWN_UPDATE_TYPE` | Unknown |
| `NEW_SESSION` | New session created |
| `USER_JOINED` | User joined the session |
| `USER_LEFT` | User left the session |
| `SESSION_DELETED` | Session was deleted |
| `YOU_LEFT` | You left the session |
| `YOU_WERE_KICKED` | You were kicked from session |
| `YOU_JOINED` | You joined a session |
| `PARTICIPANT_PROMOTED_TO_HOST` | Participant became host |
| `DISCOVERABILITY_CHANGED` | Session discoverability changed |
| `USER_KICKED` | A user was kicked |

### SessionType

| Value | Description |
|-------|-------------|
| `UNKNOWN_SESSION_TYPE` | Unknown |
| `IN_PERSON` | In-person session |
| `REMOTE` | Remote session |
| `REMOTE_V2` | Remote session v2 |

---

## Enumerations

### DeviceType

| Value | Description |
|-------|-------------|
| `UNKNOWN` | Unknown device |
| `COMPUTER` | Desktop/laptop |
| `TABLET` | Tablet device |
| `SMARTPHONE` | Mobile phone |
| `SPEAKER` | Smart speaker |
| `TV` | Television |
| `AVR` | Audio/Video receiver |
| `STB` | Set-top box |
| `AUDIO_DONGLE` | Chromecast Audio, etc. |
| `GAME_CONSOLE` | PlayStation, Xbox, etc. |
| `CAST_VIDEO` | Chromecast |
| `CAST_AUDIO` | Cast audio device |
| `AUTOMOBILE` | Car |
| `SMARTWATCH` | Watch |
| `CHROMEBOOK` | Chromebook |
| `UNKNOWN_SPOTIFY` | Unknown Spotify device |
| `CAR_THING` | Spotify Car Thing |
| `OBSERVER` | Observer device |
| `HOME_THING` | Home device |

### MemberType

| Value | Description |
|-------|-------------|
| `SPIRC_V2` | Spirc protocol version 2 |
| `SPIRC_V3` | Spirc protocol version 3 |
| `CONNECT_STATE` | Connect state |
| `CONNECT_STATE_EXTENDED` | Extended connect state |
| `ACTIVE_DEVICE_TRACKER` | Active device tracker |
| `PLAY_TOKEN` | Play token |

### Track Providers

The `provider` field in [`ProvidedTrack`](#providedtrack) indicates the track source:

| Provider | Description |
|----------|-------------|
| `context` | From the current context (playlist, album, etc.) |
| `queue` | User-added to queue |
| `autoplay` | Automatically added by autoplay feature |

### AudioOutputDeviceType

| Value | Description |
|-------|-------------|
| `UNKNOWN_AUDIO_OUTPUT_DEVICE_TYPE` | Unknown |
| `BUILT_IN_SPEAKER` | Built-in speaker |
| `LINE_OUT` | Line out |
| `BLUETOOTH` | Bluetooth |
| `AIRPLAY` | AirPlay |
| `AUTOMOTIVE` | Automotive |
| `CAR_PROJECTED` | Car projected (Android Auto, CarPlay) |

### BitrateLevel

| Value | Description |
|-------|-------------|
| `unknown_bitrate_level` | Unknown |
| `low` | Low quality (~24 kbps) |
| `normal` | Normal quality (~96 kbps) |
| `high` | High quality (~160 kbps) |
| `very_high` | Very high quality (~320 kbps) |
| `hifi` | HiFi quality (lossless) |
| `hifi24` | HiFi 24-bit |

---

## Restrictions

Restrictions indicate which actions are disallowed and why. Each field contains an array of reason strings.

```
Restrictions {
    disallow_pausing_reasons: [string]
    disallow_resuming_reasons: [string]
    disallow_seeking_reasons: [string]
    disallow_peeking_prev_reasons: [string]
    disallow_peeking_next_reasons: [string]
    disallow_skipping_prev_reasons: [string]
    disallow_skipping_next_reasons: [string]
    disallow_toggling_repeat_context_reasons: [string]
    disallow_toggling_repeat_track_reasons: [string]
    disallow_toggling_shuffle_reasons: [string]
    disallow_set_queue_reasons: [string]
    disallow_interrupting_playback_reasons: [string]
    disallow_transferring_playback_reasons: [string]
    disallow_remote_control_reasons: [string]
    disallow_inserting_into_next_tracks_reasons: [string]
    disallow_inserting_into_context_tracks_reasons: [string]
    disallow_reordering_in_next_tracks_reasons: [string]
    disallow_reordering_in_context_tracks_reasons: [string]
    disallow_removing_from_next_tracks_reasons: [string]
    disallow_removing_from_context_tracks_reasons: [string]
    disallow_updating_context_reasons: [string]
    disallow_playing_reasons: [string]
    disallow_stopping_reasons: [string]
    disallow_add_to_queue_reasons: [string]
    disallow_setting_playback_speed_reasons: [string]
    disallow_setting_modes: map<string, ModeRestrictions>
    disallow_signals: map<string, RestrictionReasons>
}
```

---

## LoggingParams

Most commands include logging parameters for analytics:

```
LoggingParams {
    interaction_ids: [string]?
    device_identifier: string?
    command_initiated_time: int64?
    page_instance_ids: [string]?
    command_id: string?
}
```

---

## Source Files

The protocol definitions can be found in:

- [`protocol/proto/connect.proto`](protocol/proto/connect.proto) - Connect state messages
- [`protocol/proto/player.proto`](protocol/proto/player.proto) - Player state messages
- [`protocol/proto/context.proto`](protocol/proto/context.proto) - Context definitions
- [`protocol/proto/transfer_state.proto`](protocol/proto/transfer_state.proto) - Transfer state
- [`protocol/proto/devices.proto`](protocol/proto/devices.proto) - Device types
- [`protocol/proto/social_connect_v2.proto`](protocol/proto/social_connect_v2.proto) - Social/Jam features

The command parsing is implemented in:

- [`core/src/dealer/protocol/request.rs`](core/src/dealer/protocol/request.rs) - Command definitions
- [`connect/src/spirc.rs`](connect/src/spirc.rs) - Command handling
