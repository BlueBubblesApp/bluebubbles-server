# BlueBubble Server

This is the back-end server for the BlueBubble App. It allows you to forward your iMessages to and from an Android device via the BlueBubbles App.

## Pre-requisites

-   NodeJS: https://nodejs.org/en/
-   Yarn Package Manager: https://yarnpkg.com/
-   Git: https://git-scm.com/

## Development

1. Clone the repository
    - `git clone git@github.com:BlueBubbleApp/BlueBubble-Server.git`
2. Navigate into the repository on your local machine
    - `cd BlueBubble-Server`
3. Install the server dependencies
    - `yarn`
4. Run the dev server (this will start both the renderer and server)
    - `yarn run start-dev`

## Structure

### Directory Map

* Backend Code: `/src/main`
* Frontend Code: `/src/renderer`
* iMessage Library: `/src/main/server/api/imessage`
    - **Description**: This directory contains all of the classes and code needed to communicate with the iMessage Chat database. We use TypeORM as our decorator library for connecting to the database. This allows us to request information from the database in an object-oriented way
* iMessage Database Models: `/src/main/server/api/imessage/entity`
    - **Description**" This directory contains all of the entities within the iMessage Chat database. These are also known as database "models". They defined the columns and their types. These files determine what "properties" are associated with each entity, and what we can get from the database table
* iMessage Database Transformers: `/src/main/server/api/imessage/transformers`
    - **Description**: This directory contains what we cann "transformers". They allow us to automatically convert values that we get from the database, as well as insert into the database. These are super helpful for the iMessage database. One instance they really help is with date conversions. iMessage stores dates as seconds since 2001. This is opposed to a "normal" seconds since EPOCH. On top of that, they switched the date formats from v10.12 to v10.13. The transformers allows us to seemlessly convert those date without having to worry about it in our "fetching" code. There are also transformers for integers to booleans as well as reaction IDs to strings
* iMessage Database Listeners: `/src/main/server/api/imessage/listeners`
    - **Description**: These classes are "listeners". They allow you to listen on certain things. For instance, the MessageListener allows you to "listen" for new messages. It does this by polling the database for new information, then "emitting" that message to whoever is listening. These classes inherit the JS EventEmitter class
* BlueBubble Server: `/src/main/server/index.ts`
    - **Description**: This class is the main entry point to the whole backend. This classes manages the ngrok connection, the config database connection, the socket.io connection, and handles any inter-process-communications (IPC) from the "renderer" (UI).
* Fronend Layouts: `/src/renderer/layouts`
    - **Description**: This directory contains the layouts for the frontend. In essence, these are the "containers" for all the pages. For example, the `Admin` layout in that directory is what shows the sidebar navigation, and all of its' children
* Frontend Views: `/src/renderer/views`
    - **Description**: The components in this directory are the "views" or "pages" within a layout. For instance, you'll find the configuration page here. It is a child within the Admin layout.
* Frontend Components: `/src/renderer/components`
    - **Description**: These are the re-usable components that you may use anywhere within the frontend. These may be "cards", or "buttons", or any other custom UI element.
* Frontend Entrypoint: `/src/renderer/app.tsx`

### Current Features

* Map the iMessage Chat database and be able to read from it
* Listen for changes in the messages database
* Configure an ngrok connection to avoid port forwarding
* Change the default socket port for the socket.io connection
* Change the default polling seconds for the message listener