# BlueBubbles Server

This is the back-end server for the BlueBubbles App. It allows you to forward your iMessages to and from an Android device via the BlueBubbles App.

## Pre-requisites

-   NodeJS: https://nodejs.org/en/
-   Git: https://git-scm.com/

**Warning**: Yarn may not work for this project. You may run into build errors.

## Development

1. Clone the repository
    - `git clone git@github.com:BlueBubblesApp/BlueBubbles-Server.git`
2. Navigate into the repository on your local machine
    - `cd BlueBubbles-Server`
3. Install the server dependencies
    - `npm install`
4. Run the dev server (this will start both the renderer and server)
    - `npm run start`

### macOS Warning

If you are using macOS 10.x and are having issues building/running the server, please downgrade the `node-mac-permissions` dependency to `v2.2.0`. The reason it's on a newer version is to fix a production crashing issue on Big Sur+. Please downgrade it manually for testing on macOS v10.x.

```bash
cd packages/server
npm install node-mac-permissions@2.2.0
```

## Structure / Directory Map

### Back-end

* Backend Code: `/bluebubbles-server/src/`
* BlueBubbles Server: `/bluebubbles-server/src/server/index.ts`
    - **Description**: This class is the main entry point to the whole backend. This classes manages the ngrok connection, the config database connection, the socket.io connection, and handles any inter-process-communications (IPC) from the "renderer" (UI).
* BlueBubbles Types: `/bluebubbles-server/src/server/types.ts`
    - **Description**: Holds the types for the BlueBubbles server. Defines what fields are required and optional, as well as which keys are required in a request/response
* iMessage Library: `/bluebubbles-server/src/server/api/imessage`
    - **Description**: This directory contains all of the classes and code needed to communicate with the iMessage Chat database. We use TypeORM as our decorator library for connecting to the database. This allows us to request information from the database in an object-oriented way
* iMessage Database Models: `/bluebubbles-server/src/server/api/imessage/entity`
    - **Description**" This directory contains all of the entities within the iMessage Chat database. These are also known as database "models". They defined the columns and their types. These files determine what "properties" are associated with each entity, and what we can get from the database table
* iMessage Database Transformers: `/bluebubbles-server/src/server/api/imessage/transformers`
    - **Description**: This directory contains what we call "transformers". They allow us to automatically convert values that we get from the database, as well as insert into the database. These are super helpful for the iMessage database. One instance they really help is with date conversions. iMessage stores dates as seconds since 2001. This is opposed to a "normal" seconds since EPOCH. On top of that, they switched the date formats from v10.12 to v10.13. The transformers allows us to seemlessly convert those date without having to worry about it in our "fetching" code. There are also transformers for integers to booleans as well as reaction IDs to strings
* iMessage Database Listeners: `/bluebubbles-server/src/server/api/imessage/listeners`
    - **Description**: These classes are "listeners". They allow you to listen on certain things. For instance, the MessageListener allows you to "listen" for new messages. It does this by polling the database for new information, then "emitting" that message to whoever is listening. These classes inherit the JS EventEmitter class
* Filesystem Lib: `/bluebubbles-server/src/fileSystem`
    - **Description**: This class allows us, and helps us, interact with the macOS filesystem. Mostly, reading/writing files to the app's directory.
* Filesystem Scripts: `/bluebubbles-server/src/fileSystem/scripts.ts`
    - **Description**: File that holds the Apple Scripts that get executed when sending a message, creating a chat, etc.
* Server Helpers: `/bluebubbles-server/src/helpers`
    - **Description**: Some helpers for executing actions from the client, or sending results back to the client
* Socket Server: `/bluebubbles-server/src/services/socket`
    - **Description**: The socket server that handles all incoming requests from connected sockets. Allows clients to request for bulk information such as getting chats, messages, etc.
* FCM Server: `/bluebubbles-server/src/services/fcm`
    - **Description**: This class will handle all communication with Google Firebase. This includes registering devices with FCM, sending notifications, etc.

### Front-end

* Frontend Code: `/bluebubbles-server-ui/src/`
* Fronend Layouts: `/bluebubbles-server-ui/src/layouts`
    - **Description**: This directory contains the layouts for the frontend. In essence, these are the "containers" for all the pages.
* Frontend Containers: `/bluebubbles-server-ui/src/containers`
    - **Description**: The components in this directory are "containers" as in they will contain all the rest of the components. This typically is some sort of navigation or SPA routing container.
* Frontend Components: `/bluebubbles-server-ui/src/components`
    - **Description**: These are the re-usable components that you may use anywhere within the frontend. These may be "cards", or "buttons", or any other custom UI element.
* Frontend Entrypoint: `/bluebubbles-server-ui/src/app.tsx`

## Current Feature-set

* Map the iMessage Chat database and be able to read from it
* Listen for changes in the messages database (new messages or updated messages)
* Configure an ngrok connection to avoid port forwarding
* Sending notifications over Google FCM to update the client with new messages or server updates
* Updating the Google FCM database with new server information (incase notification doesn't get to the device)
* Attachment chunking to avoid failed downloads on slower connections
* Change the default socket port for the socket.io connection
* Socket Handlers:
    - Add FCM Device: `add-fcm-device`
    - Get All Chats (with last message timestamp): `get-chats`
    - Get Messages from a Chat: `get-chat-messages`
    - Get Attachment by GUID: `get-attachment`
    - Get Attachment by Chunk: `get-attachment-chunk`
    - Get Last Chat Message: `get-last-chat-message`
    - Send Message: `send-message`
    - Start a Chat: `start-chat`

## Response Types

This section will describe what information is returned back to the client from the server

### Response Container

This is the basic format of all responses

#### Response Format

```typescript
const ResponseFormat = {
    status: ValidStatuses;
    message: ResponseMessages | string;
    error?: Error;
    data?: ResponseData;
};
```

#### Valid Statuses

```typescript
type ValidStatuses = 200 | 201 | 400 | 401 | 403 | 404 | 500;
```

#### Response Messages

```typescript
enum ResponseMessages {
    SUCCESS = 'Success',
    BAD_REQUEST = 'Bad Request',
    SERVER_ERROR = 'Server Error',
    UNAUTHORIZED = 'Unauthorized',
    FORBIDDEN = 'Forbidden',
    NO_DATA = 'No Data'
};
```

#### Response Data

```typescript
type ResponseData =
    MessageResponse |
    HandleResponse |
    ChatResponse |
    AttachmentResponse |
    (MessageResponse | HandleResponse | ChatResponse | AttachmentResponse)[] |
    Uint8Array |
    null;
```

### Response Data

Within each response container, there is an optional `data` key that contains any data that is returned by the server. That data includes different "views" from the database, whether it be chats, messages, etc.

#### Message Response

```typescript
type MessageResponse = {
    guid: string;
    text: string;
    handle?: HandleResponse | null;
    chats?: ChatResponse[];
    attachments?: AttachmentResponse[];
    subject: string;
    country: string;
    error: boolean;
    dateCreated: number;
    dateRead: number | null;
    dateDelivered: number | null;
    isFromMe: boolean;
    isDelayed: boolean;
    isAutoReply: boolean;
    isSystemMessage: boolean;
    isServiceMessage: boolean;
    isForward: boolean;
    isArchived: boolean;
    cacheRoomnames: string | null;
    isAudioMessage: boolean;
    datePlayed: number | null;
    itemType: number;
    groupTitle: string | null;
    isExpired: boolean;
    associatedMessageGuid: string | null;
    associatedMessageType: number | null;
    expressiveSendStyleId: string | null;
    timeExpressiveSendStyleId: number | null;
};
```

#### Chat Response

```typescript
type ChatResponse = {
    guid: string;
    participants?: HandleResponse[];
    messages?: MessageResponse[];
    style: number;
    chatIdentifier: string;
    isArchived: boolean;
    displayName: string;
    groupId: string;
};
```

#### Handle Response

```typescript
type HandleResponse = {
    messages?: MessageResponse[];
    chats?: ChatResponse[];
    address: string;
    country: string;
    uncanonicalizedId: string
};
```

#### Attachment Response

```typescript
export type AttachmentResponse = {
    guid: string;
    messages: string[];
    data: Uint8Array;
    uti: string;
    mimeType: string;
    transferState: number;
    totalBytes: number;
    isOutgoing: boolean;
    transferName: string;
    isSticker: boolean;
    hideAttachment: boolean;
};
```

#### UInt8Array Response

This response is used when chunking attachments. It allows us to send the data for an attachment in chunks. These chunks can be concatenated together to form the actual attachment. This will allow us to send large attachments over slow connections, or just receiving large attachments over normal connections. We can also use chunking to show a status (progress bar) for receiving attachments
